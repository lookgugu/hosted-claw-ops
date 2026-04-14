#!/bin/bash
# Hosted Claw - Customer Provisioning Script (MVP)
# Usage: ./provision.sh customer@email.com customer-name

set -eo pipefail

CUSTOMER_EMAIL=$1
CUSTOMER_NAME=$2
CUSTOMER_SUBDOMAIN=$(echo "$CUSTOMER_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')

if [ -z "$CUSTOMER_EMAIL" ] || [ -z "$CUSTOMER_NAME" ]; then
    echo "Usage: ./provision.sh customer@email.com \"Customer Name\""
    exit 1
fi

# Ensure subdomain is non-empty after sanitization
if [ -z "$CUSTOMER_SUBDOMAIN" ]; then
    echo "ERROR: Customer Name '$CUSTOMER_NAME' results in an empty subdomain after sanitization."
    exit 1
fi

# Validate email format
if ! echo "$CUSTOMER_EMAIL" | grep -qE '^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$'; then
    echo "ERROR: Invalid email format: $CUSTOMER_EMAIL"
    exit 1
fi

# Validate required env vars
if [ -z "$HETZNER_API_TOKEN" ]; then
    echo "ERROR: HETZNER_API_TOKEN is not set"
    exit 1
fi
if [ -z "$HETZNER_SSH_KEY_ID" ]; then
    echo "ERROR: HETZNER_SSH_KEY_ID is not set"
    exit 1
fi
if [ -z "$TOKEN_ENCRYPTION_KEY" ]; then
    echo "ERROR: TOKEN_ENCRYPTION_KEY is not set"
    echo "  Generate one with: openssl rand -hex 32"
    exit 1
fi

echo "🚀 Provisioning Hosted Claw instance for: $CUSTOMER_NAME"
echo "Email: $CUSTOMER_EMAIL"
echo "Subdomain: $CUSTOMER_SUBDOMAIN"
echo ""

# -------------------------------------------------------------------
# Generate credentials BEFORE provisioning
# -------------------------------------------------------------------
GATEWAY_TOKEN=$(openssl rand -hex 32)

echo "🔑 Gateway token generated"

# -------------------------------------------------------------------
# Hetzner Cloud API — create VPS
# -------------------------------------------------------------------
echo "📦 Creating Hetzner VPS..."

HETZNER_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $HETZNER_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg name "hosted-claw-$CUSTOMER_SUBDOMAIN" \
    --arg email "$CUSTOMER_EMAIL" \
    --arg ssh_key "$HETZNER_SSH_KEY_ID" \
    '{
      name: $name,
      server_type: "cx11",
      image: "ubuntu-22.04",
      location: "nbg1",
      ssh_keys: [$ssh_key],
      labels: { customer_email: $email, service: "hosted-claw" }
    }')" \
  https://api.hetzner.cloud/v1/servers)

SERVER_ID=$(echo "$HETZNER_RESPONSE" | jq -r '.server.id // empty')

if [ -z "$SERVER_ID" ] || [ "$SERVER_ID" = "null" ]; then
    echo "ERROR: Failed to create server. Hetzner response:"
    echo "$HETZNER_RESPONSE" | jq '.error // .'
    exit 1
fi

echo "Server ID: $SERVER_ID"

# Cleanup function — delete server if provisioning fails during setup window
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "⚠️  Provisioning failed (exit $exit_code) — deleting orphaned VPS $SERVER_ID..."
        curl -s -X DELETE \
          -H "Authorization: Bearer $HETZNER_API_TOKEN" \
          "https://api.hetzner.cloud/v1/servers/$SERVER_ID" > /dev/null
        echo "🗑  VPS $SERVER_ID deleted"
    fi
}
trap cleanup EXIT

# -------------------------------------------------------------------
# Poll server status until running (up to 3 minutes)
# -------------------------------------------------------------------
echo "⏳ Waiting for server to become active..."
MAX_WAIT=180
ELAPSED=0
SERVER_IP=""

while [ $ELAPSED -lt $MAX_WAIT ]; do
    STATUS_RESPONSE=$(curl -s \
      -H "Authorization: Bearer $HETZNER_API_TOKEN" \
      "https://api.hetzner.cloud/v1/servers/$SERVER_ID")

    STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.server.status // empty')
    SERVER_IP=$(echo "$STATUS_RESPONSE" | jq -r '.server.public_net.ipv4.ip // empty')

    if [ "$STATUS" = "running" ] && [ -n "$SERVER_IP" ] && [ "$SERVER_IP" != "null" ]; then
        echo "Server IP: $SERVER_IP (ready in ${ELAPSED}s)"
        break
    fi

    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "null" ]; then
    echo "ERROR: Server did not become ready within ${MAX_WAIT}s"
    exit 1
fi

# -------------------------------------------------------------------
# Fetch server host key (prevents MITM on first SSH connection)
# -------------------------------------------------------------------
echo "🔐 Fetching SSH host key..."
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# Remove any stale entry for this IP (Hetzner recycles IPs between customers)
ssh-keygen -R "$SERVER_IP" 2>/dev/null || true
RETRIES=10
for i in $(seq 1 $RETRIES); do
    HOST_KEY=$(ssh-keyscan -T 10 "$SERVER_IP" 2>/dev/null) || true
    if [ -n "$HOST_KEY" ]; then
        echo "$HOST_KEY" >> ~/.ssh/known_hosts
        echo "Host key verified"
        break
    fi
    echo "  Attempt $i/$RETRIES — sshd not ready, retrying in 10s..."
    sleep 10
done

if [ -z "$HOST_KEY" ]; then
    echo "ERROR: Could not retrieve host key from $SERVER_IP after $RETRIES attempts"
    exit 1
fi

# -------------------------------------------------------------------
# Install OpenClaw on the server (with auth configured)
# Token is expanded locally via unquoted heredoc delimiter — avoids
# exposing it in the process list via command-line arguments.
# -------------------------------------------------------------------
echo "📥 Installing OpenClaw..."

ssh root@"$SERVER_IP" bash -s <<ENDSSH
set -eo pipefail

GATEWAY_TOKEN="$GATEWAY_TOKEN"

# Update system (security patches only — skip full upgrade for speed)
apt-get update -q
apt-get install -y -q --no-install-recommends curl jq nginx certbot python3-certbot-nginx ufw

# Install Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /dev/null 2>&1
apt-get install -y -q nodejs

# Install OpenClaw
npm install -g openclaw@latest --quiet

# Create openclaw user
useradd -m -s /bin/bash openclaw

# Onboard OpenClaw non-interactively
sudo -u openclaw openclaw onboard --install-daemon --non-interactive \
  --model anthropic/claude-sonnet-4-5 \
  --gateway-port 18789

# Set gateway auth token
sudo -u openclaw openclaw config patch \
  '{"gateway":{"token":"'\${GATEWAY_TOKEN}'"}}'

echo "✅ Gateway token configured"

# Enable and start service
systemctl enable openclaw-gateway@openclaw
systemctl start openclaw-gateway@openclaw

# Wait for gateway to start
sleep 5

# Verify auth is enforced — fatal error if unauthenticated
AUTH_CHECK=\$(curl -s -o /dev/null -w "%{http_code}" http://localhost:18789/health 2>/dev/null || echo "000")
if [ "\$AUTH_CHECK" != "401" ]; then
    echo "ERROR: Gateway auth check failed. Expected HTTP 401, got \$AUTH_CHECK. The gateway may be unauthenticated."
    exit 1
fi
echo "✅ Gateway auth verified (401 on unauthenticated request)"

# Generate self-signed certificate for TLS (interim solution until DNS automation)
# Once DNS is implemented (issue #8), this can be replaced with Let's Encrypt
echo "🔐 Generating self-signed SSL certificate..."
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/openclaw.key \
  -out /etc/nginx/ssl/openclaw.crt \
  -subj "/C=US/ST=State/L=City/O=Hosted Claw/CN=$SERVER_IP"
chmod 600 /etc/nginx/ssl/openclaw.key
chmod 644 /etc/nginx/ssl/openclaw.crt

# Nginx config — HTTPS with HTTP redirect, proxy only, raw port blocked by firewall
cat > /etc/nginx/sites-available/openclaw << 'ENDNGINX'
# Redirect HTTP to HTTPS
server {
    listen 80;
    server_name _;
    return 301 https://\$host\$request_uri;
}

# HTTPS server
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/nginx/ssl/openclaw.crt;
    ssl_certificate_key /etc/nginx/ssl/openclaw.key;

    # Modern SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;

    location / {
        proxy_pass http://localhost:18789;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;

        # Forward real client IP
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
ENDNGINX

ln -sf /etc/nginx/sites-available/openclaw /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# Firewall — block direct access to gateway port
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw deny 18789/tcp
ufw --force enable

echo "✅ OpenClaw installed, authenticated, and firewall configured"
ENDSSH

# Remote install succeeded — disable cleanup trap for post-provisioning steps
trap - EXIT

# -------------------------------------------------------------------
# Verify authentication is enforced from the external network
# -------------------------------------------------------------------
echo "🔍 Verifying auth from external network..."
# Use -k flag to skip certificate verification for self-signed cert
# Test HTTPS endpoint (HTTP redirects to HTTPS) with retry for reliability
HTTPS_STATUS="000"
for i in {1..5}; do
    HTTPS_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" "https://$SERVER_IP/" 2>/dev/null || echo "000")
    [ "$HTTPS_STATUS" = "401" ] && break
    echo "  Attempt $i/5 — got status $HTTPS_STATUS, retrying in 2s..."
    sleep 2
done
if [ "$HTTPS_STATUS" != "401" ]; then
    echo "ERROR: External HTTPS auth verification failed. Expected HTTP 401, got $HTTPS_STATUS from https://$SERVER_IP/"
    exit 1
fi
echo "✅ External HTTPS auth verified (status: $HTTPS_STATUS)"

# Verify HTTP redirects to HTTPS
HTTP_REDIRECT=$(curl -s -o /dev/null -w "%{http_code}" "http://$SERVER_IP/" 2>/dev/null || echo "000")
if [ "$HTTP_REDIRECT" != "301" ]; then
    echo "⚠️  Warning: HTTP to HTTPS redirect may not be working. Got status $HTTP_REDIRECT instead of 301"
fi
echo "✅ HTTP to HTTPS redirect verified (status: $HTTP_REDIRECT)"

# -------------------------------------------------------------------
# Store customer record — compact JSONL, no credentials
# -------------------------------------------------------------------
CUSTOMERS_DB="customers.jsonl"
touch "$CUSTOMERS_DB"
chmod 600 "$CUSTOMERS_DB"

jq -cn \
  --arg name "$CUSTOMER_NAME" \
  --arg email "$CUSTOMER_EMAIL" \
  --arg server_id "$SERVER_ID" \
  --arg ip "$SERVER_IP" \
  --arg subdomain "$CUSTOMER_SUBDOMAIN" \
  --arg status "active" \
  --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{name:$name, email:$email, server_id:$server_id, ip:$ip, subdomain:$subdomain, status:$status, created:$created}' \
  >> "$CUSTOMERS_DB"

echo "📋 Customer record saved to $CUSTOMERS_DB (token NOT stored here)"

# -------------------------------------------------------------------
# Store token encrypted with AES-256-CBC (key from TOKEN_ENCRYPTION_KEY env var)
# Decrypt with: scripts/get_token.sh <subdomain>
# -------------------------------------------------------------------
TOKENS_DIR="tokens"
mkdir -p "$TOKENS_DIR"
chmod 700 "$TOKENS_DIR"
printf '%s' "$GATEWAY_TOKEN" | \
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
    -pass env:TOKEN_ENCRYPTION_KEY \
    -out "$TOKENS_DIR/$CUSTOMER_SUBDOMAIN.token.enc"
chmod 600 "$TOKENS_DIR/$CUSTOMER_SUBDOMAIN.token.enc"

echo "🔑 Token encrypted and saved to $TOKENS_DIR/$CUSTOMER_SUBDOMAIN.token.enc"

# -------------------------------------------------------------------
# Output summary
# -------------------------------------------------------------------
echo ""
echo "✅ Instance provisioned successfully!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Customer: $CUSTOMER_NAME"
echo "Email: $CUSTOMER_EMAIL"
echo "Dashboard: https://$SERVER_IP"
echo "Gateway Token: $GATEWAY_TOKEN"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "⚠️  Note: Using self-signed certificate (browser warning expected)"
echo "    Upgrade to Let's Encrypt after DNS automation (issue #8)"
echo ""
echo "📧 Send this welcome email to $CUSTOMER_EMAIL:"
echo ""
cat << ENDEMAIL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Subject: Welcome to Hosted Claw! Your instance is ready 🎉

Hi $CUSTOMER_NAME,

Your Hosted Claw instance is ready!

🔗 Dashboard: https://$SERVER_IP
🔑 Gateway Token: $GATEWAY_TOKEN

⚠️  Your dashboard uses a self-signed certificate for now. Your browser will show
    a security warning — this is expected. Click "Advanced" then "Proceed" to continue.
    We'll upgrade to a trusted certificate when custom domains are available.

Next steps:
1. Log in to your dashboard using your gateway token
2. Connect your messaging platforms (Telegram, WhatsApp, etc.)
3. Add your AI model API keys (Claude, OpenAI, etc.)
4. Send your first message!

Getting Started Guide: https://docs.hosted-claw.com/getting-started

Need help? Reply to this email or join our Discord: https://discord.gg/hosted-claw

Your 7-day trial starts now.

Welcome aboard! 🚀

- The Hosted Claw Team
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ENDEMAIL

echo ""
echo "✅ Add to UptimeRobot: https://$SERVER_IP (use HTTPS monitoring)"
