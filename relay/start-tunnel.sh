#!/usr/bin/env bash
set -euo pipefail

# Start the OpenClaw Cloudflare Tunnel.
# Replace YOUR_TUNNEL_TOKEN with the token from your Cloudflare dashboard
# or from the output of the setup-tunnel.sh script.

TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-YOUR_TUNNEL_TOKEN}"

if [ "$TUNNEL_TOKEN" = "YOUR_TUNNEL_TOKEN" ]; then
  echo "Error: Set CLOUDFLARE_TUNNEL_TOKEN or edit this script with your tunnel token."
  echo "Run ./relay/setup-tunnel.sh first, or get the token from:"
  echo "  https://one.dash.cloudflare.com → Zero Trust → Networks → Tunnels"
  exit 1
fi

echo "Starting OpenClaw tunnel…"
exec cloudflared tunnel run --token "${TUNNEL_TOKEN}"
