#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

echo "Installing Dongle Insomnia..."

# Install the keep-alive script
echo "Copying keep-alive.sh to /usr/local/bin/"
cp keep-alive.sh /usr/local/bin/keep-alive.sh
chmod +x /usr/local/bin/keep-alive.sh

# Install the systemd service
echo "Copying dongle-insomnia.service to /etc/systemd/system/"
cp dongle-insomnia.service /etc/systemd/system/dongle-insomnia.service

# Reload systemd and enable the service
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling and starting dongle-insomnia service..."
systemctl enable --now dongle-insomnia.service

echo "Installation complete. The service is running."
systemctl status dongle-insomnia.service --no-pager
