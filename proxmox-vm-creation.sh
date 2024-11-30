#!/bin/bash

# Proxmox VM Creation Script for Event Platform

# Configuration Variables
VMID=9001
HOSTNAME="event-platform"
STORAGE_POOL="local-lvm"
ISO_PATH="/var/lib/vz/template/iso/ubuntu-22.04-server-amd64.iso"
MEMORY=4096  # 4GB RAM
CORES=2
DISK_SIZE="32G"
NETWORK_BRIDGE="vmbr0"

# Check if VM already exists
if qm status $VMID 2>/dev/null; then
    echo "VM with ID $VMID already exists. Choose a different VMID."
    exit 1
fi

# Create VM
qm create $VMID \
    --name $HOSTNAME \
    --memory $MEMORY \
    --cores $CORES \
    --net0 virtio,bridge=$NETWORK_BRIDGE \
    --disk $STORAGE_POOL:$DISK_SIZE \
    --cdrom $ISO_PATH \
    --ostype l26

# Configure Boot
qm set $VMID --boot order=scsi0 
qm set $VMID --bootdisk scsi0

# Network Configuration
qm set $VMID --ipconfig0 ip=dhcp

# Optional: Set automatic startup
qm set $VMID --onboot 1

echo "VM $HOSTNAME created with ID $VMID"
