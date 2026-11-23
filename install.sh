
#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

echo "Starting release-fail installation..."

# Resolve absolute path of the repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME="$(whoami)"

# --------------------------------------------------
# 1. Check and install Node.js (minimum version 22)
# --------------------------------------------------

if ! command -v node >/dev/null 2>&1 || ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)'; then
  echo "Installing Node.js 22..."

  ARCH="$(dpkg --print-architecture)"

  if [[ "$ARCH" != "arm64" && "$ARCH" != "amd64" ]]; then
    echo "ERROR: This Node.js installer requires a 64-bit OS (arm64 or amd64)."
    exit 1
  fi

  sudo apt-get update
  sudo apt-get install -y curl ca-certificates

  NODE_SETUP="$(mktemp)"
  curl -fsSL https://deb.nodesource.com/setup_22.x -o "$NODE_SETUP"
  sudo bash "$NODE_SETUP"
  rm -f "$NODE_SETUP"

  sudo apt-get install -y nodejs
fi

NODE_BIN="$(command -v node)"

if ! command -v npm >/dev/null 2>&1; then
  echo "ERROR: npm is not installed"
  exit 1
fi

echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"
echo "Node binary: $NODE_BIN"

# --------------------------------------------------
# 2. Check and install python3-serial
# --------------------------------------------------

if ! /usr/bin/python3 -c "import serial" >/dev/null 2>&1; then
  echo "Installing python3-serial..."
  sudo apt-get update
  sudo apt-get install -y python3 python3-serial
else
  echo "python3-serial already available"
fi

/usr/bin/python3 -c "import serial; print('PySerial version:', serial.__version__)"

# --------------------------------------------------
# 3. Install npm dependencies
# --------------------------------------------------

echo "Installing dependencies in $SCRIPT_DIR"
cd "$SCRIPT_DIR"
npm install

# --------------------------------------------------
# 4. Disable Wi-Fi power saving
# --------------------------------------------------

if [ -d /sys/class/net/wlan0 ]; then
  if ! command -v iw >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y iw
  fi

  IW_BIN="$(command -v iw)"

  echo "Disabling Wi-Fi power saving..."
  sudo "$IW_BIN" dev wlan0 set power_save off

  # Make Wi-Fi power saving setting persistent
  sudo tee /etc/systemd/system/release-fail-wifi.service > /dev/null <<EOF
[Unit]
Description=Disable Wi-Fi power saving
After=network.target
ConditionPathExists=/sys/class/net/wlan0

[Service]
Type=oneshot
ExecStart=$IW_BIN dev wlan0 set power_save off

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl enable release-fail-wifi.service
else
  echo "Wi-Fi interface wlan0 not found, skipping."
fi

# --------------------------------------------------
# 5. Create systemd service
# --------------------------------------------------

SERVICE_FILE="/etc/systemd/system/release-fail-node.service"

echo "Creating systemd service at $SERVICE_FILE"

sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=release-fail node

[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$SCRIPT_DIR
EnvironmentFile=/etc/environment
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=$NODE_BIN $SCRIPT_DIR/release-fail-node.js
Restart=on-failure
RestartSec=3
StandardOutput=append:/var/log/release-fail-node.log
StandardError=append:/var/log/release-fail-node.log

[Install]
WantedBy=multi-user.target
EOF

# --------------------------------------------------
# 6. Reload and enable systemd service
# --------------------------------------------------

echo "Enabling release-fail-node service..."

sudo systemctl daemon-reload
sudo systemctl enable release-fail-node.service

# --------------------------------------------------
# 7. Ensure daily reboot cron exists only once
# --------------------------------------------------

if ! grep -Fxq "0 0 * * * root reboot" /etc/crontab; then
  echo "0 0 * * * root reboot" | sudo tee -a /etc/crontab > /dev/null
  echo "Daily midnight reboot configured."
else
  echo "Daily midnight reboot already configured."
fi

# --------------------------------------------------
# 8. Installation complete
# --------------------------------------------------

echo "Installation complete."
echo "Rebooting..."

sudo reboot
