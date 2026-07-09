#!/bin/bash

# Configuration
# Override by running: PVE_HOST="root@192.168.1.144" ./deploy.sh
# Or create a local .env file (ignored by git) containing: PVE_HOST=root@192.168.1.144
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi
PVE_HOST="${PVE_HOST:-root@your-proxmox-ip}"
SETUP_SCRIPT="proxmox-backup-setup.sh"
DEST_PATH="/tmp/"

echo "--- Deploying $SETUP_SCRIPT to $PVE_HOST ---"

if [ ! -f "$SETUP_SCRIPT" ]; then
    echo "Error: $SETUP_SCRIPT not found in current directory."
    exit 1
fi

scp "$SETUP_SCRIPT" "$PVE_HOST:$DEST_PATH"

if [ $? -eq 0 ]; then
    echo "--- Deployment Successful ---"
    echo "You can now run: ssh $PVE_HOST 'bash /tmp/$SETUP_SCRIPT --dry-run'"
else
    echo "Error: Deployment failed."
    exit 1
fi
