import os
from datetime import datetime
from flask import Flask, render_template, request, jsonify, session, redirect, url_for
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager, UserMixin, login_user, login_required, logout_user, current_user
from werkzeug.security import generate_password_hash, check_password_hash
from werkzeug.utils import secure_filename
import uuid
import requests
from functools import wraps
import logging
from logging.handlers import RotatingFileHandler
import redis
from rq import Queue
from PIL import Image
import jwt
from datetime import datetime, timedelta

app = Flask(__name__)

# Configuration
app.config['SECRET_KEY'] = 'your-secret-key-here'  # Change this in production
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///events.db'
app.config['UPLOAD_FOLDER'] = 'static/uploads'
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024  # 16MB max upload
app.config['ALLOWED_EXTENSIONS'] = {'png', 'jpg', 'jpeg', 'gif'}
app.config['REDIS_URL'] = 'redis://localhost:6379/0'

# Initialize extensions
db = SQLAlchemy(app)
login_manager = LoginManager(app)
login_manager.login_view = 'login'

# Redis configuration for caching and background tasks
redis_client = redis.Redis.from_url(app.config['REDIS_URL'])
task_queue = Queue(connection=redis_client)

# Ensure upload directory exists
os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)

# Configure logging
if not os.path.exists('logs'):
    os.mkdir('logs')
file_handler = RotatingFileHandler('logs/events.log', maxBytes=10240, backupCount=10)
file_handler.setFormatter(logging.Formatter(
    '%(asctime)s %(levelname)s: %(message)s [in %(pathname)s:%(lineno)d]'
))
file_handler.setLevel(logging.INFO)
app.logger.addHandler(file_handler)
app.logger.setLevel(logging.INFO)
app.logger.info('Event application startup')

# Database Models
class User(UserMixin, db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    email = db.Column(db.String(120), unique=True, nullable=False)
    password_hash = db.Column(db.String(128))
    events = db.relationship('Event', backref='author', lazy='dynamic')

    def set_password(self, password):
        self.password_hash = generate_password_hash(password)

    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

    def get_reset_token(self, expires_in=600):
        return jwt.encode(
            {'reset_password': self.id, 'exp': datetime.utcnow() + timedelta(seconds=expires_in)},
            app.config['SECRET_KEY'], algorithm='HS256')

class Event(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    category = db.Column(db.String(50), nullable=False)
    latitude = db.Column(db.Float, nullable=False)
    longitude = db.Column(db.Float, nullable=False)
    location_name = db.Column(db.String(200))
    poster_path = db.Column(db.String(200))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    event_date = db.Column(db.DateTime, nullable=False)
    user_id = db.Column(db.Integer, db.ForeignKey('user.id'))
    description = db.Column(db.Text)
    is_private = db.Column(db.Boolean, default=False)

# Helper Functions
def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in app.config['ALLOWED_EXTENSIONS']

def process_image(file_path):
    """Process uploaded image - create thumbnail and optimize"""
    try:
        with Image.open(file_path) as img:
            # Create thumbnail
            img.thumbnail((300, 300))
            thumbnail_path = f"{os.path.splitext(file_path)[0]}_thumb.jpg"
            img.save(thumbnail_path, "JPEG", quality=85, optimize=True)
            return thumbnail_path
    except Exception as e:
        app.logger.error(f"Error processing image: {e}")
        return None

def geocode_location(query):
    """Geocode address using Nominatim with caching"""
    cache_key = f"geocode:{query}"
    cached_result = redis_client.get(cache_key)
    
    if cached_result:
        return eval(cached_result)
    
    try:
        nominatim_url = "https://nominatim.openstreetmap.org/search"
        params = {
            'q': query,
            'format': 'json',
            'limit': 5
        }
        response = requests.get(nominatim_url, params=params)
        results = response.json()
        
        if results:
            locations = [{
                'display_name': result['display_name'],
                'latitude': float(result['lat']),
                'longitude': float(result['lon'])
            } for result in results]
            
            # Cache results for 1 hour
            redis_client.setex(cache_key, 3600, str(locations))
            return locations
    except Exception as e:
        app.logger.error(f"Geocoding error: {e}")
    return []

# Route Handlers
@app.route('/')
def index():
    return render_template('index.html')

@app.route('/register', methods=['GET', 'POST'])
def register():
    if request.method == 'POST':
        data = request.get_json()
        if User.query.filter_by(email=data['email']).first():
            return jsonify({'error': 'Email already registered'}), 400
        
        user = User(username=data['username'], email=data['email'])
        user.set_password(data['password'])
        db.session.add(user)
        db.session.commit()
        return jsonify({'message': 'Registration successful'})
    return render_template('register.html')

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        data = request.get_json()
        user = User.query.filter_by(email=data['email']).first()
        if user and user.check_password(data['password']):
            login_user(user)
            return jsonify({'message': 'Login successful'})
        return jsonify({'error': 'Invalid email or password'}), 401
    return render_template('login.html')

@app.route('/logout')
@login_required
def logout():
    logout_user()
    return redirect(url_for('index'))

@app.route('/geocode')
def geocode():
    query = request.args.get('query', '')
    return jsonify(geocode_location(query))

@app.route('/upload_event', methods=['POST'])
@login_required
def upload_event():
    try:
        data = request.form
        poster = request.files.get('poster')
        
        # Handle poster upload
        poster_path = None
        if poster and allowed_file(poster.filename):
            filename = secure_filename(f"{uuid.uuid4()}_{poster.filename}")
            file_path = os.path.join(app.config['UPLOAD_FOLDER'], filename)
            poster.save(file_path)
            
            # Process image in background
            task_queue.enqueue(process_image, file_path)
            poster_path = f"uploads/{filename}"

        # Create event
        event = Event(
            name=data['event_name'],
            category=data['event_category'],
            latitude=float(data['latitude']),
            longitude=float(data['longitude']),
            location_name=data['location_name'],
            poster_path=poster_path,
            event_date=datetime.strptime(data['event_date'], '%Y-%m-%d'),
            description=data.get('description', ''),
            is_private=bool(data.get('is_private', False)),
            user_id=current_user.id
        )
        
        db.session.add(event)
        db.session.commit()
        
        return jsonify({
            'status': 'success',
            'message': 'Event uploaded successfully',
            'event': {
                'id': event.id,
                'name': event.name,
                'category': event.category,
                'location_name': event.location_name,
                'poster_path': event.poster_path,
                'event_date': event.event_date.strftime('%Y-%m-%d')
            }
        })

    except Exception as e:
        app.logger.error(f"Error creating event: {e}")
        db.session.rollback()
        return jsonify({'status': 'error', 'message': str(e)}), 400

@app.route('/get_events')
def get_events():
    page = request.args.get('page', 1, type=int)
    per_page = request.args.get('per_page', 10, type=int)
    category = request.args.get('category')
    search = request.args.get('search')
    
    query = Event.query
    
    if category:
        query = query.filter_by(category=category)
    if search:
        query = query.filter(Event.name.ilike(f'%{search}%'))
    
    # Only show public events and user's private events
    if current_user.is_authenticated:
        query = query.filter(
            (Event.is_private == False) | 
            (Event.user_id == current_user.id)
        )
    else:
        query = query.filter_by(is_private=False)
    
    events = query.order_by(Event.event_date.desc()).paginate(
        page=page, per_page=per_page, error_out=False
    )
    
    return jsonify({
        'events': [{
            'id': event.id,
            'name': event.name,
            'category': event.category,
            'location_name': event.location_name,
            'latitude': event.latitude,
            'longitude': event.longitude,
            'poster_path': event.poster_path,
            'event_date': event.event_date.strftime('%Y-%m-%d'),
            'author': event.author.username,
            'is_owner': current_user.is_authenticated and event.user_id == current_user.id
        } for event in events.items],
        'total': events.total,
        'pages': events.pages,
        'current_page': events.page
    })

@app.route('/event/<int:event_id>', methods=['GET', 'PUT', 'DELETE'])
def event(event_id):
    event = Event.query.get_or_404(event_id)
    
    if request.method == 'GET':
        return jsonify({
            'id': event.id,
            'name': event.name,
            'category': event.category,
            'location_name': event.location_name,
            'latitude': event.latitude,
            'longitude': event.longitude,
            'poster_path': event.poster_path,
            'event_date': event.event_date.strftime('%Y-%m-%d'),
            'description': event.description,
            'is_private': event.is_private,
            'author': event.author.username
        })
    
    # Ensure user owns the event for PUT and DELETE
    if not current_user.is_authenticated or event.user_id != current_user.id:
        return jsonify({'error': 'Unauthorized'}), 403
    
    if request.method == 'PUT':
        data = request.get_json()
        event.name = data.get('name', event.name)
        event.category = data.get('category', event.category)
        event.description = data.get('description', event.description)
        event.is_private = data.get('is_private', event.is_private)
        
        if 'event_date' in data:
            event.event_date = datetime.strptime(data['event_date'], '%Y-%m-%d')
        
        db.session.commit()
        return jsonify({'message': 'Event updated successfully'})
    
    if request.method == 'DELETE':
        if event.poster_path:
            try:
                os.remove(os.path.join(app.config['UPLOAD_FOLDER'], event.poster_path))
            except Exception as e:
                app.logger.error(f"Error deleting poster: {e}")
        
        db.session.delete(event)
        db.session.commit()
        return jsonify({'message': 'Event deleted successfully'})

@app.errorhandler(404)
def not_found_error(error):
    return jsonify({'error': 'Not found'}), 404

@app.errorhandler(500)
def internal_error(error):
    db.session.rollback()
    return jsonify({'error': 'Internal server error'}), 500

# Initialize database
with app.app_context():
    db.create_all()

if __name__ == '__main__':
    app.run(debug=True)
