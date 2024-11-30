#!/bin/bash

# Proxmox Event Platform Deployment Script
# Warning: Run this script with sudo privileges

# Exit on any error
set -e

# Logging
LOG_FILE="/var/log/event_platform_setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check for root/sudo privileges
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root or with sudo${NC}"
   exit 1
fi

# System Update
echo -e "${YELLOW}Updating system packages...${NC}"
apt-get update && apt-get upgrade -y

# Install essential dependencies
echo -e "${YELLOW}Installing system dependencies...${NC}"
apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    nginx \
    postgresql \
    postgresql-contrib \
    libpq-dev \
    python3-dev \
    supervisor \
    certbot \
    python3-certbot-nginx \
    fail2ban \
    ufw \
    git

# Create project directory
PROJECT_DIR="/opt/event_platform"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# Setup Python Virtual Environment
python3 -m venv venv
source venv/bin/activate

# Install Python dependencies
pip install \
    flask \
    sqlalchemy \
    psycopg2-binary \
    flask-login \
    flask-wtf \
    requests \
    pillow \
    gunicorn

# Database Setup
DB_NAME="event_platform"
DB_USER="eventadmin"
DB_PASS=$(openssl rand -base64 12)

sudo -u postgres psql <<POSTGRES_SCRIPT
CREATE DATABASE $DB_NAME;
CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
POSTGRES_SCRIPT

# Save database credentials securely
echo "DATABASE_URL=postgresql://$DB_USER:$DB_PASS@localhost/$DB_NAME" > .env

# Clone Your Event Platform Repository
git clone https://github.com/DimitriGeelen/KH-Event-app.git src

# Nginx Configuration
cat > /etc/nginx/sites-available/event_platform <<NGINX_CONF
server {
    listen 80;
    server_name event.yourdomain.com;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINX_CONF

# Enable site
ln -s /etc/nginx/sites-available/event_platform /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

# Supervisor Configuration for Gunicorn
cat > /etc/supervisor/conf.d/event_platform.conf <<SUPERVISOR_CONF
[program:event_platform]
directory=$PROJECT_DIR/src
command=$PROJECT_DIR/venv/bin/gunicorn \
    --workers 3 \
    --bind unix:event_platform.sock \
    -m 007 \
    app:app
autostart=true
autorestart=true
stderr_logfile=/var/log/event_platform/error.log
stdout_logfile=/var/log/event_platform/output.log
SUPERVISOR_CONF

# Firewall Configuration
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw enable

# Final Setup
chown -R www-data:www-data "$PROJECT_DIR"
systemctl restart supervisor

echo -e "${GREEN}Event Platform Deployment Complete!${NC}"
echo -e "${YELLOW}Database Credentials:${NC}"
echo "Database Name: $DB_NAME"
echo "Database User: $DB_USER"
echo "Database Password: $DB_PASS"