#!/usr/bin/env bash
# WiFi Profile Setup Script
# - Creates a new WiFi connection profile
# - Enables auto-connect without switching to it immediately
# - Profile will automatically connect when the network is available

set -Eeuo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

# Check if NetworkManager is available
if ! command -v nmcli &> /dev/null; then
  echo "ERROR: NetworkManager (nmcli) is not installed"
  echo "Please install NetworkManager:"
  echo "  Ubuntu/Debian: sudo apt-get install network-manager"
  echo "  Fedora/RHEL:   sudo dnf install NetworkManager"
  echo "  Arch:          sudo pacman -S networkmanager"
  exit 1
fi

# Check if running with appropriate permissions
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Note: This script should be run as root for full functionality"
  echo "Run with: sudo bash $0"
  echo
  read -r -p "Continue anyway? (y/N): " CONTINUE
  if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

echo "=== WiFi Profile Setup Script ==="
echo

# Get WiFi SSID
read -r -p "Enter WiFi network name (SSID): " WIFI_SSID
while [[ -z "$WIFI_SSID" ]]; do
  read -r -p "Please enter the WiFi SSID: " WIFI_SSID
done

# Check if profile already exists
EXISTING_PROFILE=$(nmcli -t -f NAME connection show | grep "^${WIFI_SSID}$" || true)
if [[ -n "$EXISTING_PROFILE" ]]; then
  echo "WARNING: A connection profile named '$WIFI_SSID' already exists"
  read -r -p "Remove existing profile and create new one? (y/N): " REMOVE_PROFILE
  if [[ "$REMOVE_PROFILE" =~ ^[Yy]$ ]]; then
    echo "Removing existing profile..."
    nmcli connection delete "$WIFI_SSID" || true
    echo "Existing profile removed"
  else
    echo "Exiting to avoid overwriting existing profile"
    exit 1
  fi
fi

# Get WiFi password
echo
read -r -s -p "Enter WiFi password (hidden): " WIFI_PASSWORD
echo
while [[ -z "$WIFI_PASSWORD" ]]; do
  read -r -s -p "Please enter the WiFi password: " WIFI_PASSWORD
  echo
done

# Confirm password
read -r -s -p "Confirm WiFi password: " WIFI_PASSWORD_CONFIRM
echo
if [[ "$WIFI_PASSWORD" != "$WIFI_PASSWORD_CONFIRM" ]]; then
  echo "ERROR: Passwords do not match"
  exit 1
fi

# Ask about hidden network
echo
read -r -p "Is this a hidden network? (y/N): " IS_HIDDEN
if [[ "$IS_HIDDEN" =~ ^[Yy]$ ]]; then
  HIDDEN_FLAG="yes"
  echo "Will configure as hidden network"
else
  HIDDEN_FLAG="no"
fi

# Get connection priority (optional)
echo
echo "Connection priority (higher number = higher priority):"
echo "  0 = default (will connect when available)"
echo "  Higher values prefer this network over others"
read -r -p "Enter priority (default: 0): " PRIORITY
if [[ -z "$PRIORITY" ]]; then
  PRIORITY=0
elif ! [[ "$PRIORITY" =~ ^[0-9]+$ ]]; then
  echo "Invalid priority, using default (0)"
  PRIORITY=0
fi

echo
echo "=== Configuration Summary ==="
echo "SSID: $WIFI_SSID"
echo "Hidden: $HIDDEN_FLAG"
echo "Priority: $PRIORITY"
echo "Auto-connect: enabled"
echo "Auto-activate: disabled (won't connect immediately)"
echo

read -r -p "Create this WiFi profile? (Y/n): " CONFIRM
if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
  echo "Cancelled"
  exit 0
fi

# Create WiFi connection profile
echo
echo "Creating WiFi profile..."

# Build nmcli command
NMCLI_CMD=(
  nmcli connection add
  type wifi
  con-name "$WIFI_SSID"
  ifname "*"
  ssid "$WIFI_SSID"
  wifi-sec.key-mgmt wpa-psk
  wifi-sec.psk "$WIFI_PASSWORD"
  connection.autoconnect yes
  connection.autoconnect-priority "$PRIORITY"
)

# Add hidden network flag if needed
if [[ "$HIDDEN_FLAG" == "yes" ]]; then
  NMCLI_CMD+=(802-11-wireless.hidden yes)
fi

# Execute the command
if "${NMCLI_CMD[@]}" >/dev/null 2>&1; then
  echo "SUCCESS: WiFi profile '$WIFI_SSID' created successfully"
else
  echo "ERROR: Failed to create WiFi profile"
  echo "Please check your input and try again"
  exit 1
fi

# Verify profile was created
if nmcli -t -f NAME connection show | grep -q "^${WIFI_SSID}$"; then
  echo "Profile verified in NetworkManager"
else
  echo "WARNING: Profile may not have been created correctly"
fi

echo
echo "=== Setup Complete ==="
echo "WiFi Profile: $WIFI_SSID"
echo "Status: Created (not connected)"
echo
echo "The profile will automatically connect when '$WIFI_SSID' is in range."
echo "NetworkManager will handle the connection automatically."
echo
echo "Useful commands:"
echo "  nmcli connection show                    # List all connection profiles"
echo "  nmcli connection show '$WIFI_SSID'       # Show profile details"
echo "  nmcli connection up '$WIFI_SSID'         # Manually connect to this network"
echo "  nmcli connection down '$WIFI_SSID'       # Disconnect from this network"
echo "  nmcli connection modify '$WIFI_SSID' \\"
echo "    connection.autoconnect no              # Disable auto-connect"
echo "  nmcli connection delete '$WIFI_SSID'     # Remove this profile"
echo "  nmcli device wifi list                   # Scan for available networks"
echo "  nmcli device wifi rescan                 # Trigger a new WiFi scan"
echo
echo "To check if the network is available:"
echo "  nmcli device wifi list | grep '$WIFI_SSID'"
echo
