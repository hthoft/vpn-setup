#!/usr/bin/env bash
# Kiosk Setup Script
# - Installs X server, Openbox, and Chromium
# - Configures automatic X startup without cursor
# - Sets up Openbox autostart for kiosk mode

set -Eeuo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

# Detect the actual user (even when running with sudo)
if [ -n "${SUDO_USER:-}" ]; then
  TARGET_USER="$SUDO_USER"
elif [ "${EUID:-$(id -u)}" -ne 0 ]; then
  TARGET_USER="$(whoami)"
else
  # Running as root directly, prompt for target user
  read -r -p "Enter the target username for kiosk setup: " TARGET_USER
  while [[ -z "$TARGET_USER" ]]; do
    read -r -p "Please enter a username: " TARGET_USER
  done
fi

TARGET_USER_HOME=$(eval echo "~$TARGET_USER")

# Check if running as root
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "ERROR: This script must be run as root."
  echo "Please run with: sudo $0"
  exit 1
fi

# Verify target user exists
if ! id "$TARGET_USER" &>/dev/null; then
  echo "ERROR: User '$TARGET_USER' does not exist."
  exit 1
fi

echo "=== Kiosk Setup Script ==="
echo "Setting up kiosk mode for user: $TARGET_USER"
echo

# Update package lists
echo "Updating package lists..."
apt-get update

# Install required packages
echo "Installing X server, Openbox, Chromium, and dependencies..."
apt-get install -y \
  xserver-xorg \
  x11-xserver-utils \
  xinit \
  openbox \
  chromium \
  unclutter

echo "Packages installed successfully"
echo

# Create .bash_profile for automatic X startup without cursor
BASH_PROFILE="$TARGET_USER_HOME/.bash_profile"
echo "Creating $BASH_PROFILE..."

cat > "$BASH_PROFILE" << 'EOF'
# Start X server on login (tty1 only) without cursor
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec startx -- -nocursor
fi
EOF

chown "$TARGET_USER:$TARGET_USER" "$BASH_PROFILE"
chmod 644 "$BASH_PROFILE"
echo "Created $BASH_PROFILE"

# Create Openbox autostart directory
OPENBOX_AUTOSTART_DIR="/etc/xdg/openbox"
mkdir -p "$OPENBOX_AUTOSTART_DIR"

# Create Openbox autostart file
OPENBOX_AUTOSTART="$OPENBOX_AUTOSTART_DIR/autostart"
echo "Creating $OPENBOX_AUTOSTART..."

cat > "$OPENBOX_AUTOSTART" << EOF
#!/bin/bash
setxkbmap -option terminate:ctrl_alt_bksp &
xset s off
xset -dpms
xset s noblank
sleep 2

# paths
PROJECT="\$HOME/maprova_qr"
VENV_PYTHON="\$PROJECT/venv/bin/python"
APP="\$PROJECT/src/main.py"

# run Python app in background
"\$VENV_PYTHON" "\$APP" &

# start Chromium
chromium --kiosk --no-first-run --no-default-browser-check http://127.0.0.1:5000 &
EOF

chmod 755 "$OPENBOX_AUTOSTART"
echo "Created $OPENBOX_AUTOSTART"

# Create .xinitrc for the user to use Openbox
XINITRC="$TARGET_USER_HOME/.xinitrc"
echo "Creating $XINITRC..."

cat > "$XINITRC" << 'EOF'
#!/bin/bash
exec openbox-session
EOF

chown "$TARGET_USER:$TARGET_USER" "$XINITRC"
chmod 755 "$XINITRC"
echo "Created $XINITRC"

echo
echo "=== Kiosk Setup Complete ==="
echo
echo "Configuration summary:"
echo "  User: $TARGET_USER"
echo "  .bash_profile: $BASH_PROFILE (auto-starts X without cursor)"
echo "  .xinitrc: $XINITRC (launches Openbox)"
echo "  Openbox autostart: $OPENBOX_AUTOSTART"
echo
echo "The kiosk will:"
echo "  1. Auto-start X server on tty1 login (without cursor)"
echo "  2. Launch Openbox window manager"
echo "  3. Disable screen saver and power management"
echo "  4. Start the Python app from ~/maprova_qr/src/main.py"
echo "  5. Open Chromium in kiosk mode at http://127.0.0.1:5000"
echo
echo "To enable auto-login for $TARGET_USER, you may want to configure:"
echo "  sudo systemctl edit getty@tty1.service"
echo "  And add: ExecStart=-/sbin/agetty --autologin $TARGET_USER --noclear %I \$TERM"
echo
echo "Reboot to test the kiosk setup:"
echo "  sudo reboot"
echo
