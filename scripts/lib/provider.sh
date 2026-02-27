#!/bin/bash
# DigitalOcean provider abstraction — create, poll, and delete droplets.
#
# Required env vars:
#   DIGITALOCEAN_API_TOKEN  — API token with Read + Write scope
#   DIGITALOCEAN_SSH_KEY_ID — SSH key ID registered in DigitalOcean
#
# Optional env vars (with defaults):
#   DO_REGION — Droplet region  (default: nyc1)
#   DO_SIZE   — Droplet size    (default: s-1vcpu-1gb)
#   DO_IMAGE  — Droplet image   (default: ubuntu-22-04-x64)

: "${DO_REGION:=nyc1}"
: "${DO_SIZE:=s-1vcpu-1gb}"
: "${DO_IMAGE:=ubuntu-22-04-x64}"

DO_API="https://api.digitalocean.com/v2"

_do_curl() {
    curl -s -H "Authorization: Bearer $DIGITALOCEAN_API_TOKEN" \
         -H "Content-Type: application/json" \
         "$@"
}

# provider_create <name> <email>
# Prints the new droplet ID to stdout. Returns 1 on failure.
provider_create() {
    local name=$1 email=$2

    local response
    response=$(_do_curl -X POST \
      -d "$(jq -n \
        --arg name "$name" \
        --arg email "$email" \
        --arg ssh_key "$DIGITALOCEAN_SSH_KEY_ID" \
        --arg size "$DO_SIZE" \
        --arg image "$DO_IMAGE" \
        --arg region "$DO_REGION" \
        '{
          name: $name,
          size: $size,
          image: $image,
          region: $region,
          ssh_keys: [$ssh_key],
          tags: ["hosted-claw", ("customer:" + $email)]
        }')" \
      "$DO_API/droplets")

    local id
    id=$(echo "$response" | jq -r '.droplet.id // empty')

    if [ -z "$id" ] || [ "$id" = "null" ]; then
        echo "ERROR: Failed to create droplet. DigitalOcean response:" >&2
        echo "$response" | jq '.message // .' >&2
        return 1
    fi

    echo "$id"
}

# provider_get_status <droplet_id>
# Prints "<status> <public_ipv4>" to stdout (space-separated).
provider_get_status() {
    local id=$1

    local response
    response=$(_do_curl "$DO_API/droplets/$id")

    local status ip
    status=$(echo "$response" | jq -r '.droplet.status // empty')
    ip=$(echo "$response" | jq -r '[.droplet.networks.v4[] | select(.type=="public")][0].ip_address // empty')

    echo "$status $ip"
}

# provider_is_ready <droplet_id>
# Returns 0 when the droplet is active with a public IP, 1 otherwise.
# Exports PROVIDER_IP on success for the caller to use.
provider_is_ready() {
    local id=$1

    local result status ip
    result=$(provider_get_status "$id")
    status=${result%% *}
    ip=${result#* }

    if [ "$status" = "active" ] && [ -n "$ip" ] && [ "$ip" != "null" ]; then
        export PROVIDER_IP="$ip"
        return 0
    fi
    return 1
}

# provider_delete <droplet_id>
provider_delete() {
    local id=$1
    _do_curl -X DELETE "$DO_API/droplets/$id" > /dev/null
}
