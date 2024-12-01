#!/bin/bash

# install.sh

echo "Starting Event Manager Application Installation..."

# Check if Python is installed
if ! command -v python3 &> /dev/null; then
    echo "Python3 is not installed. Please install Python3 first."
    exit 1
fi

# Check if pip is installed
if ! command -v pip3 &> /dev/null; then
    echo "pip3 is not installed. Please install pip3 first."
    exit 1
fi

# Create virtual environment
echo "Creating virtual environment..."
python3 -m venv venv

# Activate virtual environment
echo "Activating virtual environment..."
source venv/bin/activate

# Install required packages
echo "Installing required packages..."
pip install flask flask-sqlalchemy

# Create directory structure
echo "Creating directory structure..."
mkdir -p templates static

# Create app directory if it doesn't exist
if [ ! -d "event_manager" ]; then
    mkdir event_manager
fi

# Move to app directory
cd event_manager

# Download the application files
echo "Downloading application files..."

# Create app.py
cat > app.py << 'EOL'
from flask import Flask, render_template, request, jsonify
from flask_sqlalchemy import SQLAlchemy
from datetime import datetime

app = Flask(__name__)
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///events.db'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
db = SQLAlchemy(app)

class Event(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    title = db.Column(db.String(100), nullable=False)
    date = db.Column(db.DateTime, nullable=False)
    category = db.Column(db.String(50), nullable=False)
    description = db.Column(db.Text, nullable=False)
    location = db.Column(db.String(200), nullable=False)
    latitude = db.Column(db.Float, nullable=False)
    longitude = db.Column(db.Float, nullable=False)

with app.app_context():
    db.create_all()

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/add_event', methods=['POST'])
def add_event():
    data = request.json
    new_event = Event(
        title=data['title'],
        date=datetime.strptime(data['date'], '%Y-%m-%d'),
        category=data['category'],
        description=data['description'],
        location=data['location'],
        latitude=float(data['latitude']),
        longitude=float(data['longitude'])
    )
    db.session.add(new_event)
    db.session.commit()
    return jsonify({'message': 'Event added successfully'})

@app.route('/search_events')
def search_events():
    query = request.args.get('query', '')
    category = request.args.get('category', '')
    
    events = Event.query
    if query:
        events = events.filter(
            (Event.title.contains(query)) |
            (Event.description.contains(query)) |
            (Event.location.contains(query))
        )
    if category:
        events = events.filter_by(category=category)
    
    events = events.all()
    return jsonify([{
        'id': e.id,
        'title': e.title,
        'date': e.date.strftime('%Y-%m-%d'),
        'category': e.category,
        'description': e.description,
        'location': e.location,
        'latitude': e.latitude,
        'longitude': e.longitude
    } for e in events])

if __name__ == '__main__':
    app.run(debug=True)
EOL

# Create templates directory and index.html
mkdir -p templates
cat > templates/index.html << 'EOL'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Event Manager</title>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.7.1/leaflet.css" />
    <style>
        #map {
            height: 400px;
            margin-bottom: 20px;
        }
        .form-group {
            margin-bottom: 15px;
        }
        .event-list {
            margin-top: 20px;
        }
        .event-card {
            border: 1px solid #ddd;
            padding: 10px;
            margin-bottom: 10px;
            border-radius: 5px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Event Manager</h1>
        
        <!-- Search Form -->
        <div class="search-form">
            <input type="text" id="searchQuery" placeholder="Search events...">
            <select id="categoryFilter">
                <option value="">All Categories</option>
                <option value="Conference">Conference</option>
                <option value="Meeting">Meeting</option>
                <option value="Social">Social</option>
                <option value="Other">Other</option>
            </select>
            <button onclick="searchEvents()">Search</button>
        </div>

        <!-- Map -->
        <div id="map"></div>

        <!-- Add Event Form -->
        <form id="eventForm">
            <div class="form-group">
                <label>Title:</label>
                <input type="text" id="title" required>
            </div>
            <div class="form-group">
                <label>Date:</label>
                <input type="date" id="date" required>
            </div>
            <div class="form-group">
                <label>Category:</label>
                <select id="category" required>
                    <option value="Conference">Conference</option>
                    <option value="Meeting">Meeting</option>
                    <option value="Social">Social</option>
                    <option value="Other">Other</option>
                </select>
            </div>
            <div class="form-group">
                <label>Description:</label>
                <textarea id="description" required></textarea>
            </div>
            <div class="form-group">
                <label>Location:</label>
                <input type="text" id="location" required>
                <input type="hidden" id="latitude">
                <input type="hidden" id="longitude">
            </div>
            <button type="submit">Add Event</button>
        </form>

        <!-- Event List -->
        <div id="eventList" class="event-list"></div>
    </div>

    <script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.7.1/leaflet.js"></script>
    <script>
        let map = L.map('map').setView([0, 0], 2);
        L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
            attribution: '© OpenStreetMap contributors'
        }).addTo(map);

        let markers = [];

        map.on('click', function(e) {
            document.getElementById('latitude').value = e.latlng.lat;
            document.getElementById('longitude').value = e.latlng.lng;
            
            markers.forEach(marker => map.removeLayer(marker));
            markers = [];
            let marker = L.marker(e.latlng).addTo(map);
            markers.push(marker);
        });

        document.getElementById('eventForm').addEventListener('submit', async (e) => {
            e.preventDefault();
            
            const eventData = {
                title: document.getElementById('title').value,
                date: document.getElementById('date').value,
                category: document.getElementById('category').value,
                description: document.getElementById('description').value,
                location: document.getElementById('location').value,
                latitude: document.getElementById('latitude').value,
                longitude: document.getElementById('longitude').value
            };

            try {
                const response = await fetch('/add_event', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify(eventData)
                });
                
                if (response.ok) {
                    alert('Event added successfully!');
                    searchEvents();
                    e.target.reset();
                }
            } catch (error) {
                console.error('Error:', error);
                alert('Error adding event');
            }
        });

        async function searchEvents() {
            const query = document.getElementById('searchQuery').value;
            const category = document.getElementById('categoryFilter').value;
            
            try {
                const response = await fetch(`/search_events?query=${query}&category=${category}`);
                const events = await response.json();
                
                markers.forEach(marker => map.removeLayer(marker));
                markers = [];
                
                const eventList = document.getElementById('eventList');
                eventList.innerHTML = '';
                
                events.forEach(event => {
                    const marker = L.marker([event.latitude, event.longitude])
                        .bindPopup(`<b>${event.title}</b><br>${event.date}<br>${event.location}`)
                        .addTo(map);
                    markers.push(marker);
                    
                    const eventCard = document.createElement('div');
                    eventCard.className = 'event-card';
                    eventCard.innerHTML = `
                        <h3>${event.title}</h3>
                        <p>Date: ${event.date}</p>
                        <p>Category: ${event.category}</p>
                        <p>Location: ${event.location}</p>
                        <p>${event.description}</p>
                    `;
                    eventList.appendChild(eventCard);
                });
            } catch (error) {
                console.error('Error:', error);
                alert('Error searching events');
            }
        }

        searchEvents();
    </script>
</body>
</html>
EOL

# Create requirements.txt
cat > requirements.txt << 'EOL'
flask
flask-sqlalchemy
EOL

# Make the script executable
chmod +x app.py

echo "Installation completed!"
echo "To run the application:"
echo "1. Make sure you're in the virtual environment (source venv/bin/activate)"
echo "2. Navigate to the event_manager directory"
echo "3. Run 'python app.py'"
echo "4. Open your browser and go to http://localhost:5000"

# Create a run script
cat > run.sh << 'EOL'
#!/bin/bash
source venv/bin/activate
python app.py
EOL

chmod +x run.sh

echo "You can also run the application using ./run.sh"
