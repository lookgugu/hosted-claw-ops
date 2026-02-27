#!/bin/bash
# Hosted Claw — Remote server setup (runs over SSH)
#
# Installs OpenClaw, configures nginx reverse proxy, sets up firewall,
# and verifies gateway authentication.
#
# Usage (called by provision.sh — not meant to be run directly):
#   ssh root@<ip> bash -s < scripts/setup-server.sh
#
# Expects GATEWAY_TOKEN to be set in the environment on the remote side.
# provision.sh injects it via env var before piping this script.

set -eo pipefail

if [ -z "$GATEWAY_TOKEN" ]; then
    echo "ERROR: GATEWAY_TOKEN is not set"
    exit 1
fi

# Update system (security patches only — skip full upgrade for speed)
apt-get update -q
apt-get install -y -q --no-install-recommends curl jq nginx certbot python3-certbot-nginx ufw

# Install Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /dev/null 2>&1
apt-get install -y -q nodejs

# Install OpenClaw
npm install -g openclaw@latest --quiet

# Create openclaw user (skip if already exists)
id openclaw &>/dev/null || useradd -m -s /bin/bash openclaw

# Onboard OpenClaw non-interactively (skip if already onboarded)
if [ ! -f /home/openclaw/.openclaw/config.json ]; then
    sudo -u openclaw openclaw onboard --install-daemon --non-interactive \
      --model anthropic/claude-sonnet-4-5 \
      --gateway-port 18789
fi

# Set gateway auth token (always update — supports token rotation)
sudo -u openclaw openclaw config patch \
  '{"gateway":{"token":"'"${GATEWAY_TOKEN}"'"}}'

echo "✅ Gateway token configured"

# Enable and (re)start service — restart is safe on first run too
systemctl enable openclaw-gateway@openclaw
systemctl restart openclaw-gateway@openclaw

# Wait for gateway to start
sleep 5

# Verify auth is enforced — fatal error if unauthenticated
AUTH_CHECK=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:18789/health 2>/dev/null || echo "000")
if [ "$AUTH_CHECK" != "401" ]; then
    echo "ERROR: Gateway auth check failed. Expected HTTP 401, got $AUTH_CHECK. The gateway may be unauthenticated."
    exit 1
fi
echo "✅ Gateway auth verified (401 on unauthenticated request)"

# Nginx config — proxy only, raw port blocked by firewall
cat > /etc/nginx/sites-available/openclaw << 'ENDNGINX'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:18789;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
    }
}
ENDNGINX

ln -sf /etc/nginx/sites-available/openclaw /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# Firewall — block direct access to gateway port (ufw rules are idempotent)
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw deny 18789/tcp
echo "y" | ufw enable

echo "✅ OpenClaw installed, authenticated, and firewall configured"
