#!/bin/bash
# Hosted Claw - Token Retrieval Helper
# Decrypts and prints a customer's gateway token to stdout.
#
# Usage: TOKEN_ENCRYPTION_KEY=<key> ./scripts/get_token.sh <subdomain>
# Example: TOKEN_ENCRYPTION_KEY="$TOKEN_ENCRYPTION_KEY" ./scripts/get_token.sh acme-corp

set -eo pipefail

CUSTOMER_SUBDOMAIN=$1

if [ -z "$CUSTOMER_SUBDOMAIN" ]; then
    echo "Usage: ./scripts/get_token.sh <subdomain>" >&2
    exit 1
fi

if [ -z "$TOKEN_ENCRYPTION_KEY" ]; then
    echo "ERROR: TOKEN_ENCRYPTION_KEY is not set" >&2
    exit 1
fi

TOKENS_DIR="$(dirname "$0")/../tokens"
TOKEN_FILE="$TOKENS_DIR/$CUSTOMER_SUBDOMAIN.token.enc"

if [ ! -f "$TOKEN_FILE" ]; then
    echo "ERROR: No token found for subdomain '$CUSTOMER_SUBDOMAIN'" >&2
    echo "  Expected: $TOKEN_FILE" >&2
    exit 1
fi

openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
    -pass env:TOKEN_ENCRYPTION_KEY \
    -in "$TOKEN_FILE"
