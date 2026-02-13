#!/usr/bin/env bash
set -euo pipefail

# ─── Cloudflare Tunnel Setup for OpenClaw ───
# Run this once on the Mac that hosts OpenClaw.
# It installs cloudflared, authenticates with Cloudflare,
# creates a named tunnel, and configures it to forward to OpenClaw.

TUNNEL_NAME="openclaw-tunnel"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"

echo "==> Installing cloudflared via Homebrew…"
if ! command -v cloudflared &>/dev/null; then
  brew install cloudflared
else
  echo "    cloudflared already installed."
fi

echo ""
echo "==> Authenticating with Cloudflare…"
echo "    A browser window will open — log in and select your domain."
cloudflared tunnel login

echo ""
echo "==> Creating tunnel '${TUNNEL_NAME}'…"
if cloudflared tunnel list | grep -q "${TUNNEL_NAME}"; then
  echo "    Tunnel '${TUNNEL_NAME}' already exists — skipping create."
else
  cloudflared tunnel create "${TUNNEL_NAME}"
fi

TUNNEL_ID=$(cloudflared tunnel list --output json | python3 -c "
import json, sys
tunnels = json.load(sys.stdin)
for t in tunnels:
    if t['name'] == '${TUNNEL_NAME}':
        print(t['id'])
        break
")

CONFIG_DIR="$HOME/.cloudflared"
CONFIG_FILE="${CONFIG_DIR}/config.yml"

echo ""
echo "==> Writing config to ${CONFIG_FILE}…"
cat > "${CONFIG_FILE}" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CONFIG_DIR}/${TUNNEL_ID}.json

ingress:
  - service: http://localhost:${OPENCLAW_PORT}
EOF

echo ""
echo "============================================"
echo "  Tunnel created: ${TUNNEL_NAME}"
echo "  Tunnel ID:      ${TUNNEL_ID}"
echo ""
echo "  NEXT STEPS:"
echo "  1. Create a DNS route for the tunnel:"
echo "     cloudflared tunnel route dns ${TUNNEL_NAME} openclaw.yourdomain.com"
echo ""
echo "  2. Start the tunnel:"
echo "     ./relay/start-tunnel.sh"
echo ""
echo "  3. Set the public URL in Secrets.swift:"
echo "     static let openClawRelayURL = \"https://openclaw.yourdomain.com\""
echo ""
echo "  4. (Optional) Install the launchd plist for auto-start:"
echo "     cp relay/com.cloudflare.openclaw-tunnel.plist ~/Library/LaunchAgents/"
echo "     launchctl load ~/Library/LaunchAgents/com.cloudflare.openclaw-tunnel.plist"
echo "============================================"
