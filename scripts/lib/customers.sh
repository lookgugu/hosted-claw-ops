#!/bin/bash
# Customer record operations — centralizes JSONL read/write/delete.
#
# All functions operate on $CUSTOMERS_DB (default: customers.jsonl).
# Uses jq for proper JSON field matching (no substring bugs).

: "${CUSTOMERS_DB:=customers.jsonl}"

# customer_add <name> <email> <server_id> <ip> <subdomain>
# Appends a new record. Creates the file if it doesn't exist.
customer_add() {
    local name=$1 email=$2 server_id=$3 ip=$4 subdomain=$5

    touch "$CUSTOMERS_DB"
    chmod 600 "$CUSTOMERS_DB"

    jq -cn \
      --arg name "$name" \
      --arg email "$email" \
      --arg server_id "$server_id" \
      --arg ip "$ip" \
      --arg subdomain "$subdomain" \
      --arg status "active" \
      --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{name:$name, email:$email, server_id:$server_id, ip:$ip, subdomain:$subdomain, status:$status, created:$created}' \
      >> "$CUSTOMERS_DB"
}

# customer_find <subdomain>
# Prints the JSON record to stdout. Returns 1 if not found.
customer_find() {
    local subdomain=$1

    if [ ! -f "$CUSTOMERS_DB" ]; then
        return 1
    fi

    local record
    record=$(jq -c --arg s "$subdomain" 'select(.subdomain == $s)' "$CUSTOMERS_DB" | tail -1)

    if [ -z "$record" ]; then
        return 1
    fi

    echo "$record"
}

# customer_remove <subdomain>
# Removes all records matching the subdomain. Returns 1 if file doesn't exist.
customer_remove() {
    local subdomain=$1

    if [ ! -f "$CUSTOMERS_DB" ]; then
        return 1
    fi

    local temp
    temp=$(mktemp)
    jq -c --arg s "$subdomain" 'select(.subdomain != $s)' "$CUSTOMERS_DB" > "$temp" || true
    mv "$temp" "$CUSTOMERS_DB"
    chmod 600 "$CUSTOMERS_DB"
}
