#!/bin/bash
# Hosted Claw - Customer Provisioning Script (MVP)
# Usage: ./provision.sh customer@email.com customer-name

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/provider.sh"
source "$SCRIPT_DIR/lib/retry.sh"
source "$SCRIPT_DIR/lib/customers.sh"

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
if [ -z "$DIGITALOCEAN_API_TOKEN" ]; then
    echo "ERROR: DIGITALOCEAN_API_TOKEN is not set"
    exit 1
fi
if [ -z "$DIGITALOCEAN_SSH_KEY_ID" ]; then
    echo "ERROR: DIGITALOCEAN_SSH_KEY_ID is not set"
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
# Create droplet
# -------------------------------------------------------------------
echo "📦 Creating DigitalOcean Droplet..."

SERVER_ID=$(provider_create "hosted-claw-$CUSTOMER_SUBDOMAIN" "$CUSTOMER_EMAIL")
echo "Droplet ID: $SERVER_ID"

# Cleanup function — delete droplet if provisioning fails
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "⚠️  Provisioning failed (exit $exit_code) — deleting orphaned Droplet $SERVER_ID..."
        provider_delete "$SERVER_ID"
        echo "🗑  Droplet $SERVER_ID deleted"
    fi
}
trap cleanup EXIT

# -------------------------------------------------------------------
# Poll droplet status until active (up to 3 minutes)
# -------------------------------------------------------------------
echo "⏳ Waiting for droplet to become active..."

if ! retry 180 5 provider_is_ready "$SERVER_ID"; then
    echo "ERROR: Droplet did not become ready within 180s"
    exit 1
fi

SERVER_IP="$PROVIDER_IP"
echo "Droplet IP: $SERVER_IP"

# -------------------------------------------------------------------
# Fetch server host key (prevents MITM on first SSH connection)
# -------------------------------------------------------------------
echo "🔐 Fetching SSH host key..."
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# Remove any stale entry for this IP (DigitalOcean recycles IPs between droplets)
ssh-keygen -R "$SERVER_IP" 2>/dev/null || true

fetch_host_key() {
    HOST_KEY=$(ssh-keyscan -T 10 "$SERVER_IP" 2>/dev/null) || true
    [ -n "$HOST_KEY" ]
}

if ! retry 100 10 fetch_host_key; then
    echo "ERROR: Could not retrieve host key from $SERVER_IP after retries"
    exit 1
fi

echo "$HOST_KEY" >> ~/.ssh/known_hosts
echo "Host key verified"

# -------------------------------------------------------------------
# Install OpenClaw on the server
# Token is passed via env var on the SSH command — the remote script
# reads it from $GATEWAY_TOKEN, avoiding process-list exposure.
# -------------------------------------------------------------------
echo "📥 Installing OpenClaw..."

ssh -o "SendEnv GATEWAY_TOKEN" root@"$SERVER_IP" \
  GATEWAY_TOKEN="$GATEWAY_TOKEN" bash -s < "$SCRIPT_DIR/setup-server.sh"

# Remote install succeeded — disable cleanup trap for post-provisioning steps
trap - EXIT

# -------------------------------------------------------------------
# Verify authentication is enforced from the external network
# -------------------------------------------------------------------
echo "🔍 Verifying auth from external network..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$SERVER_IP/" 2>/dev/null || echo "000")
if [ "$HTTP_STATUS" != "401" ]; then
    echo "ERROR: External auth verification failed. Expected HTTP 401, got $HTTP_STATUS from http://$SERVER_IP/"
    exit 1
fi
echo "✅ External auth verified (status: $HTTP_STATUS)"

# -------------------------------------------------------------------
# Store customer record — compact JSONL, no credentials
# -------------------------------------------------------------------
customer_add "$CUSTOMER_NAME" "$CUSTOMER_EMAIL" "$SERVER_ID" "$SERVER_IP" "$CUSTOMER_SUBDOMAIN"

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
echo "Dashboard: http://$SERVER_IP"
echo "Gateway Token: $GATEWAY_TOKEN"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📧 Send this welcome email to $CUSTOMER_EMAIL:"
echo ""
cat << ENDEMAIL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Subject: Welcome to Hosted Claw! Your instance is ready 🎉

Hi $CUSTOMER_NAME,

Your Hosted Claw instance is ready!

🔗 Dashboard: http://$SERVER_IP
🔑 Gateway Token: $GATEWAY_TOKEN

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
echo "✅ Add to UptimeRobot: http://$SERVER_IP"
