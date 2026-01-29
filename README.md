# dongle-insomnia

A tiny Linux keepalive script + systemd service to prevent some USB-C Ethernet dongles from going to sleep when the link is idle.

## What it does

Runs a loop that sends a single `ping` periodically (default: every 1s). This produces traffic so the dongle stays awake.

## Install (systemd)

The easiest option is to run the interactive installer:

```bash
sudo ./install.sh
```

Or install manually:

1) Copy the script into place and make it executable:

```bash
sudo install -m 0755 scripts/keep-dongle-awake.sh /usr/local/bin/keep-dongle-awake.sh
```

2) Copy the service unit:

```bash
sudo install -m 0644 systemd/keep-dongle-awake.service /etc/systemd/system/keep-dongle-awake.service
```

3) (Optional) Create `/etc/default/keep-dongle-awake` for configuration:

```bash
sudo tee /etc/default/keep-dongle-awake >/dev/null <<'EOF'
# Ping target (default: default gateway, else 1.1.1.1)
TARGET=1.1.1.1

# Set this to your USB ethernet interface (recommended)
# Example: INTERFACE=enp0s20f0u2
INTERFACE=

# Seconds between pings
INTERVAL=1

# Ping timeout seconds
TIMEOUT=1
EOF
```

4) Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now keep-dongle-awake.service
```

## Find your dongle interface name

```bash
ip link
```
Look for something like `enx...` or `enp*s*u*` that appears when the dongle is plugged in.

## Verify it’s running

```bash
systemctl status keep-dongle-awake.service
journalctl -u keep-dongle-awake.service -f
```

## Notes

- This intentionally keeps generating traffic; if you need to minimize traffic, increase `INTERVAL`.
- If the cable is unplugged (carrier down) and `INTERFACE` is set, the script backs off automatically.
