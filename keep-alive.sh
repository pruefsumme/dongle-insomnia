#!/bin/bash

# Configuration
INTERVAL=5

# Try to detect the default gateway
TARGET=$(ip route | grep default | awk '{print $3}' | head -n 1)

# Fallback if detection fails
if [ -z "$TARGET" ]; then
    TARGET="8.8.8.8"
fi

echo "Starting keep-alive script. Pinging $TARGET every $INTERVAL seconds."

while true; do
    ping -c 1 $TARGET > /dev/null 2>&1
    sleep $INTERVAL
done
