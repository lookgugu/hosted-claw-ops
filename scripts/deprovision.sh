#!/bin/bash
# Hosted Claw - Customer Deprovisioning Script
# Deletes the DigitalOcean droplet, removes the customer record, and
# removes the encrypted token file.
#
# Usage: ./deprovision.sh <subdomain>

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/provider.sh"
source "$SCRIPT_DIR/lib/customers.sh"

CUSTOMER_SUBDOMAIN=$1

if [ -z "$CUSTOMER_SUBDOMAIN" ]; then
    echo "Usage: ./deprovision.sh <subdomain>"
    exit 1
fi

if [ -z "$DIGITALOCEAN_API_TOKEN" ]; then
    echo "ERROR: DIGITALOCEAN_API_TOKEN is not set"
    exit 1
fi

TOKENS_DIR="tokens"

# Find the customer record (uses jq for exact field matching)
RECORD=$(customer_find "$CUSTOMER_SUBDOMAIN") || {
    echo "ERROR: No customer found with subdomain '$CUSTOMER_SUBDOMAIN'"
    exit 1
}

CUSTOMER_NAME=$(echo "$RECORD" | jq -r '.name')
SERVER_ID=$(echo "$RECORD" | jq -r '.server_id')
SERVER_IP=$(echo "$RECORD" | jq -r '.ip')

echo "⚠️  About to deprovision:"
echo "  Customer:  $CUSTOMER_NAME"
echo "  Subdomain: $CUSTOMER_SUBDOMAIN"
echo "  Droplet:   $SERVER_ID ($SERVER_IP)"
echo ""
read -rp "Type 'yes' to confirm: " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# Delete the droplet
echo "🗑  Deleting droplet $SERVER_ID..."
provider_delete "$SERVER_ID"
echo "  Droplet deleted"

# Remove customer record from JSONL (exact jq field match)
customer_remove "$CUSTOMER_SUBDOMAIN"
echo "  Customer record removed from $CUSTOMERS_DB"

# Remove encrypted token
TOKEN_FILE="$TOKENS_DIR/$CUSTOMER_SUBDOMAIN.token.enc"
if [ -f "$TOKEN_FILE" ]; then
    rm "$TOKEN_FILE"
    echo "  Token file removed: $TOKEN_FILE"
fi

# Clean up known_hosts entry
ssh-keygen -R "$SERVER_IP" 2>/dev/null || true

echo ""
echo "✅ $CUSTOMER_NAME ($CUSTOMER_SUBDOMAIN) fully deprovisioned"
