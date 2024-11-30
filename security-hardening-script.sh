#!/bin/bash

# Proxmox Security Hardening Script

# Disable Root SSH Login
sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config

# Enable SSH Key Authentication
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Configure Fail2Ban for SSH
cat > /etc/fail2ban/jail.local <<FAIL2BAN_CONF
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
FAIL2BAN_CONF

# Additional Firewall Rules
ufw limit ssh
ufw deny from 10.0.0.0/8
ufw deny from 172.16.0.0/12
ufw deny from 192.168.0.0/16

# Install and Configure Lynis (Security Auditing)
apt-get install -y lynis
lynis audit system

# Automatic Security Updates
dpkg-reconfigure -plow unattended-upgrades

# Disable Unnecessary Services
systemctl disable bluetooth
systemctl disable cups
systemctl disable avahi-daemon

# Set Password Complexity
cat >> /etc/login.defs <<PASSWORD_CONF
PASS_MAX_DAYS 90
PASS_MIN_DAYS 7
PASS_WARN_AGE 14
PASSWORD_CONF

# Install and Configure Intrusion Detection
apt-get install -y rkhunter chkrootkit
rkhunter --update
rkhunter --propupd

# Kernel Hardening
cat >> /etc/sysctl.conf <<KERNEL_HARDENING
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable packet forwarding
net.ipv4.ip_forward = 0

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Prevent against common DoS attacks
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Log suspicious packets
net.ipv4.conf.all.log_martians = 1
KERNEL_HARDENING

sysctl -p

echo "Security Hardening Complete!"
