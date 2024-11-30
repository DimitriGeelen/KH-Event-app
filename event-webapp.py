# requirements.txt
fastapi==0.109.1
python-jose==3.3.0
passlib==1.7.4
python-multipart==0.0.6
sqlalchemy==2.0.25
pydantic==2.6.1
pydantic-settings==2.1.0
pillow==10.2.0
redis==5.0.1
celery==5.3.6
uvicorn==0.27.0
python-dotenv==1.0.0
geopy==2.4.1
loguru==0.7.2
boto3==1.34.14
alembic==1.13.1

# config.py
from pydantic_settings import BaseSettings
from functools import lru_cache

class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql://user:password@localhost/eventdb"
    SECRET_KEY: str = "your-secret-key"
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 30
    REDIS_URL: str = "redis://localhost"
    AWS_ACCESS_KEY_ID: str = "your-access-key"
    AWS_SECRET_ACCESS_KEY: str = "your-secret-key"
    AWS_BUCKET_NAME: str = "your-bucket"
    
    class Config:
        env_file = ".env"

@lru_cache()
def get_settings():
    return Settings()

# models.py
from sqlalchemy import Column, Integer, String, DateTime, ForeignKey, Float
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import relationship
from datetime import datetime

Base = declarative_base()

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True, index=True)
    email = Column(String, unique=True, index=True)
    hashed_password = Column(String)
    events = relationship("Event", back_populates="owner")

class Event(Base):
    __tablename__ = "events"
    id = Column(Integer, primary_key=True, index=True)
    title = Column(String, index=True)
    description = Column(String)
    date = Column(DateTime)
    location = Column(String)
    latitude = Column(Float)
    longitude = Column(Float)
    image_url = Column(String)
    owner_id = Column(Integer, ForeignKey("users.id"))
    owner = relationship("User", back_populates="events")
    created_at = Column(DateTime, default=datetime.utcnow)

# schemas.py
from pydantic import BaseModel
from datetime import datetime
from typing import Optional

class UserBase(BaseModel):
    email: str

class UserCreate(UserBase):
    password: str

class User(UserBase):
    id: int
    
    class Config:
        from_attributes = True

class EventBase(BaseModel):
    title: str
    description: str
    date: datetime
    location: str
    latitude: float
    longitude: float

class EventCreate(EventBase):
    pass

class Event(EventBase):
    id: int
    image_url: Optional[str]
    owner_id: int
    created_at: datetime
    
    class Config:
        from_attributes = True

# auth.py
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
from passlib.context import CryptContext
from datetime import datetime, timedelta
from sqlalchemy.orm import Session
from . import models, schemas
from .config import get_settings

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="token")

def verify_password(plain_password, hashed_password):
    return pwd_context.verify(plain_password, hashed_password)

def get_password_hash(password):
    return pwd_context.hash(password)

def create_access_token(data: dict):
    settings = get_settings()
    to_encode = data.copy()
    expire = datetime.utcnow() + timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, settings.SECRET_KEY, algorithm=settings.ALGORITHM)

def get_current_user(token: str = Depends(oauth2_scheme), db: Session = Depends(get_db)):
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        settings = get_settings()
        payload = jwt.decode(token, settings.SECRET_KEY, algorithms=[settings.ALGORITHM])
        email: str = payload.get("sub")
        if email is None:
            raise credentials_exception
    except JWTError:
        raise credentials_exception
    user = get_user_by_email(db, email=email)
    if user is None:
        raise credentials_exception
    return user

# main.py
from fastapi import FastAPI, Depends, HTTPException, status, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session
from celery import Celery
from redis import Redis
from loguru import logger
import boto3
from . import models, schemas, auth
from .database import engine, get_db
from typing import List
import io
from PIL import Image

# Initialize FastAPI app
app = FastAPI()

# Configure CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Initialize Redis
redis_client = Redis.from_url(get_settings().REDIS_URL)

# Initialize Celery
celery_app = Celery('tasks', broker=get_settings().REDIS_URL)

# Configure logging
logger.add("app.log", rotation="500 MB")

# Create database tables
models.Base.metadata.create_all(bind=engine)

# User routes
@app.post("/users/", response_model=schemas.User)
def create_user(user: schemas.UserCreate, db: Session = Depends(get_db)):
    db_user = get_user_by_email(db, email=user.email)
    if db_user:
        raise HTTPException(status_code=400, detail="Email already registered")
    hashed_password = auth.get_password_hash(user.password)
    db_user = models.User(email=user.email, hashed_password=hashed_password)
    db.add(db_user)
    db.commit()
    db.refresh(db_user)
    return db_user

@app.post("/token")
def login_for_access_token(form_data: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    user = authenticate_user(db, form_data.username, form_data.password)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect username or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    access_token = auth.create_access_token(data={"sub": user.email})
    return {"access_token": access_token, "token_type": "bearer"}

# Event routes
@app.post("/events/", response_model=schemas.Event)
def create_event(
    event: schemas.EventCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(auth.get_current_user)
):
    db_event = models.Event(**event.dict(), owner_id=current_user.id)
    db.add(db_event)
    db.commit()
    db.refresh(db_event)
    return db_event

@app.get("/events/", response_model=List[schemas.Event])
def get_events(
    skip: int = 0,
    limit: int = 10,
    search: str = None,
    db: Session = Depends(get_db)
):
    # Check cache first
    cache_key = f"events:{skip}:{limit}:{search}"
    cached_events = redis_client.get(cache_key)
    
    if cached_events:
        return cached_events
    
    query = db.query(models.Event)
    
    if search:
        query = query.filter(models.Event.title.ilike(f"%{search}%"))
    
    events = query.offset(skip).limit(limit).all()
    
    # Cache results
    redis_client.setex(cache_key, 300, events)  # Cache for 5 minutes
    
    return events

@app.post("/events/{event_id}/image")
async def upload_event_image(
    event_id: int,
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    current_user: models.User = Depends(auth.get_current_user)
):
    event = db.query(models.Event).filter(models.Event.id == event_id).first()
    if not event or event.owner_id != current_user.id:
        raise HTTPException(status_code=404, detail="Event not found or unauthorized")
    
    # Process image
    image = Image.open(io.BytesIO(await file.read()))
    # Resize image to thumbnail
    image.thumbnail((800, 800))
    
    # Upload to S3
    s3_client = boto3.client(
        's3',
        aws_access_key_id=get_settings().AWS_ACCESS_KEY_ID,
        aws_secret_access_key=get_settings().AWS_SECRET_ACCESS_KEY
    )
    
    bucket = get_settings().AWS_BUCKET_NAME
    key = f"events/{event_id}/{file.filename}"
    
    # Convert image to bytes
    img_byte_arr = io.BytesIO()
    image.save(img_byte_arr, format=image.format)
    img_byte_arr = img_byte_arr.getvalue()
    
    try:
        s3_client.put_object(Bucket=bucket, Key=key, Body=img_byte_arr)
        image_url = f"https://{bucket}.s3.amazonaws.com/{key}"
        
        # Update event with image URL
        event.image_url = image_url
        db.commit()
        
        return {"image_url": image_url}
    except Exception as e:
        logger.error(f"Error uploading image: {str(e)}")
        raise HTTPException(status_code=500, detail="Error uploading image")

# Background tasks
@celery_app.task
def process_event_images():
    # Process event images in background
    pass

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
