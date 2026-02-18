#!/bin/bash
# Hosted Claw - Customer Provisioning Script (MVP)
# Usage: ./provision.sh customer@email.com customer-name

set -e  # Exit on error

CUSTOMER_EMAIL=$1
CUSTOMER_NAME=$2
CUSTOMER_SUBDOMAIN=$(echo "$CUSTOMER_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

if [ -z "$CUSTOMER_EMAIL" ] || [ -z "$CUSTOMER_NAME" ]; then
    echo "Usage: ./provision.sh customer@email.com \"Customer Name\""
    exit 1
fi

echo "🚀 Provisioning Hosted Claw instance for: $CUSTOMER_NAME"
echo "Email: $CUSTOMER_EMAIL"
echo "Subdomain: $CUSTOMER_SUBDOMAIN"
echo ""

# -------------------------------------------------------------------
# OPTION 1: Hetzner Cloud API (1 VPS per customer)
# -------------------------------------------------------------------
# Requires: Hetzner API token in environment variable HETZNER_API_TOKEN
# Docs: https://docs.hetzner.cloud/

echo "📦 Creating Hetzner VPS..."

# Create server
SERVER_ID=$(curl -s -X POST \
  -H "Authorization: Bearer $HETZNER_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"hosted-claw-$CUSTOMER_SUBDOMAIN\",
    \"server_type\": \"cx11\",
    \"image\": \"ubuntu-22.04\",
    \"location\": \"nbg1\",
    \"ssh_keys\": [\"$HETZNER_SSH_KEY_ID\"],
    \"labels\": {
      \"customer_email\": \"$CUSTOMER_EMAIL\",
      \"service\": \"hosted-claw\"
    }
  }" \
  https://api.hetzner.cloud/v1/servers | jq -r '.server.id')

echo "Server ID: $SERVER_ID"

# Wait for server to be ready
echo "⏳ Waiting for server to boot..."
sleep 30

# Get server IP
SERVER_IP=$(curl -s -H "Authorization: Bearer $HETZNER_API_TOKEN" \
  https://api.hetzner.cloud/v1/servers/$SERVER_ID | jq -r '.server.public_net.ipv4.ip')

echo "Server IP: $SERVER_IP"

# -------------------------------------------------------------------
# Install OpenClaw on the server
# -------------------------------------------------------------------
echo "📥 Installing OpenClaw..."

ssh -o StrictHostKeyChecking=no root@$SERVER_IP << 'ENDSSH'
# Update system
apt-get update && apt-get upgrade -y

# Install Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

# Install OpenClaw
npm install -g openclaw@latest

# Create openclaw user
useradd -m -s /bin/bash openclaw

# Install as daemon
sudo -u openclaw openclaw onboard --install-daemon --non-interactive \
  --model anthropic/claude-sonnet-4-5 \
  --gateway-port 18789

# Enable and start service
systemctl enable openclaw-gateway@openclaw
systemctl start openclaw-gateway@openclaw

# Install nginx reverse proxy
apt-get install -y nginx certbot python3-certbot-nginx

# Basic nginx config (SSL later)
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
nginx -t && systemctl reload nginx

# Basic firewall
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "✅ OpenClaw installed and running"
ENDSSH

# -------------------------------------------------------------------
# Generate customer credentials
# -------------------------------------------------------------------
DASHBOARD_URL="http://$SERVER_IP:18789"
TEMP_PASSWORD=$(openssl rand -base64 12)

echo ""
echo "✅ Instance provisioned successfully!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Customer: $CUSTOMER_NAME"
echo "Email: $CUSTOMER_EMAIL"
echo "Dashboard: $DASHBOARD_URL"
echo "Server IP: $SERVER_IP"
echo "Password: $TEMP_PASSWORD"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# -------------------------------------------------------------------
# Save to customer tracking sheet (CSV append)
# -------------------------------------------------------------------
echo "$CUSTOMER_NAME,$CUSTOMER_EMAIL,$DASHBOARD_URL,$SERVER_IP,$TEMP_PASSWORD,active,$(date +%Y-%m-%d)" >> customers.csv

# -------------------------------------------------------------------
# Send welcome email (manual for now)
# -------------------------------------------------------------------
echo "📧 Copy this welcome email and send to $CUSTOMER_EMAIL:"
echo ""
cat << ENDEMAIL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Subject: Welcome to Hosted Claw! Your instance is ready 🎉

Hi $CUSTOMER_NAME,

Your Hosted Claw instance is ready! Here's how to get started:

🔗 Dashboard: $DASHBOARD_URL
📧 Login: $CUSTOMER_EMAIL
🔑 Temporary password: $TEMP_PASSWORD

Next steps:
1. Log in to your dashboard
2. Change your password (Settings → Security)
3. Connect your messaging platforms (Telegram, WhatsApp, etc.)
4. Add your AI model API keys (Claude, OpenAI, etc.)
5. Send your first message!

Getting Started Guide: https://docs.hosted-claw.com/getting-started

Need help? Reply to this email or join our Discord: https://discord.gg/hosted-claw

Your 7-day trial starts now. You won't be charged again until $(date -d "+7 days" +%Y-%m-%d).

Welcome aboard! 🚀

- The Hosted Claw Team

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ENDEMAIL

echo ""
echo "✅ Provisioning complete! Add to UptimeRobot: $DASHBOARD_URL"
echo ""

# -------------------------------------------------------------------
# OPTION 2: DigitalOcean (alternative)
# -------------------------------------------------------------------
# Uncomment to use DO instead of Hetzner
# Requires: doctl CLI + DO API token

# doctl compute droplet create "hosted-claw-$CUSTOMER_SUBDOMAIN" \
#   --image ubuntu-22-04-x64 \
#   --size s-1vcpu-1gb \
#   --region nyc3 \
#   --ssh-keys $DO_SSH_KEY_ID \
#   --tag-names hosted-claw \
#   --wait

# -------------------------------------------------------------------
# OPTION 3: Docker on Shared VPS (for scale)
# -------------------------------------------------------------------
# TODO: Docker Compose setup for multi-tenant
# - One docker-compose.yml with service per customer
# - Nginx proxy with subdomain routing
# - Resource limits per container
# Build this after first 20 customers

# -------------------------------------------------------------------
# Next steps (manual for MVP)
# -------------------------------------------------------------------
# 1. Send welcome email (copy from above)
# 2. Add to UptimeRobot monitoring
# 3. Add to customer tracking sheet
# 4. Join their Discord/support channel
# 5. Schedule follow-up email (3 days: "How's it going?")
