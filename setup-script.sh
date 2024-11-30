#!/bin/bash

# Create directories
mkdir -p KH-Event-app
cd KH-Event-app
mkdir -p static/uploads
mkdir -p templates
mkdir -p logs

# Create virtual environment
python -m venv venv
source venv/bin/activate

# Create the files
cat > requirements.txt << 'EOF'
flask==2.1.0
flask-sqlalchemy==3.0.2
flask-login==0.6.2
werkzeug==2.1.1
requests==2.26.0
redis==4.5.1
rq==1.11.1
pillow==9.3.0
pyjwt==2.6.0
EOF

cat > app.py << 'EOF'
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
app.config['SECRET_KEY'] = 'your-secret-key-here'
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///events.db'
app.config['UPLOAD_FOLDER'] = 'static/uploads'
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024
app.config['ALLOWED_EXTENSIONS'] = {'png', 'jpg', 'jpeg', 'gif'}

# Initialize extensions
db = SQLAlchemy(app)
login_manager = LoginManager(app)
login_manager.login_view = 'login'

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

@login_manager.user_loader
def load_user(id):
    return User.query.get(int(id))

def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in app.config['ALLOWED_EXTENSIONS']

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/geocode')
def geocode():
    query = request.args.get('query', '')
    try:
        nominatim_url = "https://nominatim.openstreetmap.org/search"
        params = {
            'q': query,
            'format': 'json',
            'limit': 5
        }
        response = requests.get(nominatim_url, params=params)
        results = response.json()
        
        locations = [{
            'display_name': result['display_name'],
            'latitude': float(result['lat']),
            'longitude': float(result['lon'])
        } for result in results]
        
        return jsonify(locations)
    except Exception as e:
        app.logger.error(f"Geocoding error: {e}")
        return jsonify([])

@app.route('/upload_event', methods=['POST'])
@login_required
def upload_event():
    try:
        data = request.form
        poster = request.files.get('poster')
        
        poster_path = None
        if poster and allowed_file(poster.filename):
            filename = secure_filename(f"{uuid.uuid4()}_{poster.filename}")
            file_path = os.path.join(app.config['UPLOAD_FOLDER'], filename)
            poster.save(file_path)
            poster_path = f"uploads/{filename}"

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
                'poster_path': event.poster_path
            }
        })

    except Exception as e:
        app.logger.error(f"Error creating event: {e}")
        return jsonify({'status': 'error', 'message': str(e)}), 400

@app.route('/get_events')
def get_events():
    try:
        events = Event.query.all()
        return jsonify([{
            'id': event.id,
            'name': event.name,
            'category': event.category,
            'location_name': event.location_name,
            'latitude': event.latitude,
            'longitude': event.longitude,
            'poster_path': event.poster_path,
            'event_date': event.event_date.strftime('%Y-%m-%d')
        } for event in events])
    except Exception as e:
        app.logger.error(f"Error fetching events: {e}")
        return jsonify([])

# Initialize database
with app.app_context():
    db.create_all()

if __name__ == '__main__':
    app.run(debug=True)
EOF

cat > templates/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Event Manager</title>
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.7.1/dist/leaflet.css" />
    <script src="https://unpkg.com/leaflet@1.7.1/dist/leaflet.js"></script>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        #map { height: 400px; }
    </style>
</head>
<body class="bg-gray-100 p-8">
    <div class="container mx-auto max-w-2xl">
        <div class="bg-white rounded-lg shadow p-6">
            <h1 class="text-2xl font-bold mb-4">Event Upload</h1>
            
            <form id="eventForm" class="space-y-4">
                <input 
                    type="text" 
                    name="event_name" 
                    placeholder="Event Name" 
                    required 
                    class="w-full p-2 border rounded"
                >
                
                <select 
                    name="event_category" 
                    required 
                    class="w-full p-2 border rounded"
                >
                    <option value="">Select Category</option>
                    <option value="Music">Music</option>
                    <option value="Art">Art</option>
                    <option value="Technology">Technology</option>
                    <option value="Sports">Sports</option>
                    <option value="Food">Food</option>
                </select>

                <input 
                    type="date" 
                    name="event_date" 
                    required 
                    class="w-full p-2 border rounded"
                >

                <div>
                    <input 
                        type="text" 
                        id="locationSearch" 
                        placeholder="Search location..." 
                        class="w-full p-2 border rounded"
                    >
                    <div id="searchResults" class="mt-2"></div>
                </div>

                <div id="map" class="rounded-lg border"></div>
                <input type="hidden" name="latitude" id="latitude" required>
                <input type="hidden" name="longitude" id="longitude" required>
                <input type="hidden" name="location_name" id="location_name" required>

                <input 
                    type="file" 
                    name="poster" 
                    accept="image/*" 
                    class="w-full p-2 border rounded"
                >

                <button type="submit" class="w-full bg-blue-500 text-white p-2 rounded hover:bg-blue-600">
                    Upload Event
                </button>
            </form>
        </div>

        <div id="eventsList" class="mt-6 space-y-4">
            <!-- Events will be populated here -->
        </div>
    </div>

    <script>
        let map, marker;

        // Initialize map
        function initMap() {
            map = L.map('map').setView([0, 0], 2);
            L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
                attribution: '© OpenStreetMap contributors'
            }).addTo(map);

            map.on('click', function(e) {
                setLocation(e.latlng.lat, e.latlng.lng, 'Custom location');
            });
        }

        // Set location
        function setLocation(lat, lng, name) {
            if (marker) map.removeLayer(marker);
            marker = L.marker([lat, lng]).addTo(map);
            map.setView([lat, lng], 13);

            document.getElementById('latitude').value = lat;
            document.getElementById('longitude').value = lng;
            document.getElementById('location_name').value = name;
        }

        // Location search
        document.getElementById('locationSearch').addEventListener('input', async (e) => {
            const query = e.target.value;
            if (query.length < 3) return;

            try {
                const response = await fetch(`/geocode?query=${encodeURIComponent(query)}`);
                const locations = await response.json();
                
                const results = document.getElementById('searchResults');
                results.innerHTML = locations.map(loc => `
                    <div class="p-2 hover:bg-gray-100 cursor-pointer"
                         onclick="setLocation(${loc.latitude}, ${loc.longitude}, '${loc.display_name}')">
                        ${loc.display_name}
                    </div>
                `).join('');
            } catch (error) {
                console.error('Search error:', error);
            }
        });

        // Form submission
        document.getElementById('eventForm').addEventListener('submit', async (e) => {
            e.preventDefault();
            
            try {
                const formData = new FormData(e.target);
                const response = await fetch('/upload_event', {
                    method: 'POST',
                    body: formData
                });
                
                const result = await response.json();
                if (result.status === 'success') {
                    alert('Event uploaded successfully!');
                    e.target.reset();
                    loadEvents();
                } else {
                    throw new Error(result.message);
                }
            } catch (error) {
                alert('Error: ' + error.message);
            }
        });

        // Load events
        async function loadEvents() {
            try {
                const response = await fetch('/get_events');
                const events = await response.json();
                
                const eventsList = document.getElementById('eventsList');
                eventsList.innerHTML = events.map(event => `
                    <div class="bg-white rounded-lg shadow p-4">
                        <h3 class="font-bold">${event.name}</h3>
                        <p class="text-gray-600">${event.category}</p>
                        <p>${event.location_name}</p>
                        <p>Date: ${event.event_date}</p>
                        ${event.poster_path ? 
                            `<img src="${event.poster_path}" class="mt-2 max-h-48 object-contain">` 
                            : ''}
                    </div>
                `).join('');
            } catch (error) {
                console.error('Error loading events:', error);
            }
        }

        // Initialize
        document.addEventListener('DOMContentLoaded', () => {
            initMap();
            loadEvents();
        });
    </script>
</body>
</html>
EOF

# Install dependencies
pip install -r requirements.txt

echo "Setup complete! You can now run the application with: python app.py"
