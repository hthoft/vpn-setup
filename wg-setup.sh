#!/usr/bin/env bash
# Simple WireGuard Setup Script
# - Cleans up existing WireGuard installation
# - Installs WireGuard + dependencies
# - Generates keys if needed
# - Creates wg0.conf with user-specified IP
# - Pushes configuration to VPN server at 188.245.233.206

set -Eeuo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

# Check root
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "=== WireGuard Setup Script ==="
echo

# Get server IP from user
read -r -p "What is the WireGuard server IP address? ": " SERVER_IP
while [[ -z "$SERVER_IP" ]]; do
  read -r -p "Please enter the server IP address: " SERVER_IP
done

# Construct API URLs
PUSH_SERVER="http://$SERVER_IP:8080/rpi-pushconf"
SERVER_INFO_URL="http://$SERVER_IP:8080/wg/server-info"

echo "Server: $SERVER_IP"
echo

# Get server configuration and next available IP
echo "Requesting server configuration and available IP..."
SERVER_RESPONSE=$(curl -s --connect-timeout 10 --max-time 15 "$SERVER_INFO_URL" || echo "")

if [ -z "$SERVER_RESPONSE" ]; then
  echo "❌ Could not reach server at $SERVER_IP:8080"
  echo "Please check:"
  echo "  - Server IP address is correct"
  echo "  - Server is running and accessible"
  echo "  - Port 8080 is open"
  exit 1
fi

# Parse server response
SERVER_OK=$(echo "$SERVER_RESPONSE" | jq -r '.ok // false')
if [ "$SERVER_OK" != "true" ]; then
  ERROR_MSG=$(echo "$SERVER_RESPONSE" | jq -r '.error // "Unknown error"')
  echo "❌ Server error: $ERROR_MSG"
  exit 1
fi

# Extract server configuration
WG_SERVER_PUBKEY=$(echo "$SERVER_RESPONSE" | jq -r '.server_public_key')
SERVER_PORT=$(echo "$SERVER_RESPONSE" | jq -r '.server_port // "51820"')
WG_LAST=$(echo "$SERVER_RESPONSE" | jq -r '.ip_last_octet')
WG_ADDR="10.0.0.$WG_LAST/24"
WG_SERVER_ENDPOINT="$SERVER_IP:$SERVER_PORT"

echo "✅ Server configuration received:"
echo "   Public Key: ${WG_SERVER_PUBKEY:0:16}..."
echo "   Endpoint: $WG_SERVER_ENDPOINT"
echo "   Assigned IP: $WG_ADDR"

echo
echo "Client IP will be: $WG_ADDR"
echo

# Stop existing WireGuard service
echo "Stopping WireGuard service if running..."
systemctl stop wg-quick@wg0 2>/dev/null || true
systemctl disable wg-quick@wg0 2>/dev/null || true

# Clean up old configuration
echo "Cleaning up old configuration..."
rm -f /etc/wireguard/wg0.conf
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

# Install WireGuard and dependencies
echo "Installing WireGuard and dependencies..."
apt-get update -qq
apt-get install -y -qq wireguard wireguard-tools resolvconf curl jq

# Generate keys if they don't exist
umask 077
if [ ! -f /etc/wireguard/privatekey ]; then
  echo "Generating new WireGuard keys..."
  wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
else
  echo "Using existing WireGuard keys..."
  if [ ! -f /etc/wireguard/publickey ]; then
    wg pubkey < /etc/wireguard/privatekey > /etc/wireguard/publickey
  fi
fi

PRIVKEY="$(cat /etc/wireguard/privatekey)"
PUBKEY="$(cat /etc/wireguard/publickey)"

# Create WireGuard configuration
echo
echo "Creating WireGuard configuration..."
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $PRIVKEY
Address = $WG_ADDR
DNS = 1.1.1.1

[Peer]
PublicKey = $WG_SERVER_PUBKEY
Endpoint = $WG_SERVER_ENDPOINT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/wg0.conf

echo
echo "=== WireGuard Configuration Created ==="
echo "Public Key: $PUBKEY"
echo "Address: $WG_ADDR"
echo

# Get system information
HOSTNAME="$(hostname)"
IP_ADDR="$(hostname -I | awk '{print $1}' || echo "unknown")"

# Push configuration to server
echo "Pushing configuration to VPN server..."
WG_CONFIG_CONTENT="$(cat /etc/wireguard/wg0.conf)"

PAYLOAD=$(jq -n \
  --arg hostname "$HOSTNAME" \
  --arg ip "$IP_ADDR" \
  --arg wg_if "wg0" \
  --arg wg_public_key "$PUBKEY" \
  --arg wg_config "$WG_CONFIG_CONTENT" \
  '{
    hostname: $hostname,
    ip: $ip,
    wg_if: $wg_if,
    wg_public_key: $wg_public_key,
    wg_config: $wg_config
  }')

PUSH_RESPONSE=$(curl -X POST "$PUSH_SERVER" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  --connect-timeout 10 \
  --max-time 30 \
  --silent \
  --show-error \
  --write-out "\nHTTP_CODE:%{http_code}" || echo "HTTP_CODE:000")

HTTP_CODE=$(echo "$PUSH_RESPONSE" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)
RESPONSE_BODY=$(echo "$PUSH_RESPONSE" | sed 's/HTTP_CODE:[0-9]*$//')

if [ "$HTTP_CODE" = "200" ]; then
  echo
  echo "✅ Configuration successfully pushed to server!"
  
  # Check if peer was auto-configured
  if echo "$RESPONSE_BODY" | jq -e '.wg_configured == true' >/dev/null 2>&1; then
    SERVER_MSG=$(echo "$RESPONSE_BODY" | jq -r '.message // "Peer configured"')
    echo "✅ $SERVER_MSG"
    echo "   Server has automatically added your peer to WireGuard!"
  elif echo "$RESPONSE_BODY" | jq -e '.wg_configured == false' >/dev/null 2>&1; then
    WARN_MSG=$(echo "$RESPONSE_BODY" | jq -r '.warning // "Auto-config failed"')
    echo "⚠️  Warning: $WARN_MSG"
    echo "   You may need to manually add the peer on the server."
  fi
else
  echo
  echo "⚠️  Warning: Failed to push configuration to server (HTTP $HTTP_CODE)."
  echo "You may need to manually add this peer to the server:"
  echo
  echo "[Peer]"
  echo "PublicKey = $PUBKEY"
  echo "AllowedIPs = ${WG_ADDR%/*}/32"
  echo "PersistentKeepalive = 25"
  echo
fi

# Enable and start WireGuard
echo
echo "Enabling and starting WireGuard..."
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

# Wait a moment for the interface to come up
sleep 2

# Test WireGuard
echo
echo "=== WireGuard Status ==="
wg show wg0 || true
echo

# Test connectivity
echo "Testing connectivity..."
echo "Testing VPN tunnel..."
if timeout 5 ping -c 3 -W 2 10.0.0.1 >/dev/null 2>&1; then
  echo "✅ VPN tunnel working - can reach gateway (10.0.0.1)"
else
  echo "⚠️  Cannot ping VPN gateway (10.0.0.1)"
fi

echo "Testing internet through VPN..."
if timeout 5 ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then
  echo "✅ Internet connectivity through VPN working"
else
  echo "⚠️  No internet connectivity through VPN"
fi

echo "Testing DNS resolution..."
if timeout 5 nslookup google.com >/dev/null 2>&1; then
  echo "✅ DNS resolution working"
else
  echo "⚠️  DNS resolution not working"
fi

echo
echo "=== Setup Complete ==="
echo "Server: $SERVER_IP:$SERVER_PORT"
echo "Hostname: $HOSTNAME"
echo "Local IP: $IP_ADDR"
echo "VPN IP: $WG_ADDR"
echo "Client Public Key: ${PUBKEY:0:16}..."
echo "Server Public Key: ${WG_SERVER_PUBKEY:0:16}..."
echo
echo "Configuration pushed to: $PUSH_SERVER"
echo "Peer automatically configured on server."
echo
echo "Useful commands:"
echo "  sudo systemctl status wg-quick@wg0    # Check service status"
echo "  sudo wg show                          # Show WireGuard status"
echo "  sudo journalctl -u wg-quick@wg0 -f    # View logs  "
echo "  sudo systemctl restart wg-quick@wg0   # Restart tunnel"
echo "  curl ifconfig.me                      # Check public IP (should show server IP)"
echo
