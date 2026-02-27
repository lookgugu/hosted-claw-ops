# hosted-claw-ops

Deployment and operations scripts for [Hosted Claw](https://hosted-claw.com) — managed OpenClaw hosting.

## Scripts

### `scripts/provision.sh`
Provisions a new customer OpenClaw instance on DigitalOcean.

```bash
./scripts/provision.sh customer@email.com "Customer Name"
```

**Required env vars:**
- `DIGITALOCEAN_API_TOKEN` — DigitalOcean API token (Read + Write)
- `DIGITALOCEAN_SSH_KEY_ID` — SSH key ID registered in DigitalOcean
- `TOKEN_ENCRYPTION_KEY` — 32-byte hex key used to encrypt customer tokens at rest

**Optional env vars (droplet configuration):**
- `DO_REGION` — DigitalOcean region (default: `nyc1`)
- `DO_SIZE` — Droplet size slug (default: `s-1vcpu-1gb`)
- `DO_IMAGE` — Droplet image slug (default: `ubuntu-22-04-x64`)

### `scripts/deprovision.sh`
Tears down a customer instance — deletes the droplet, removes the customer record, and deletes the encrypted token.

```bash
./scripts/deprovision.sh <subdomain>
```

Prompts for confirmation before taking any action.

### `scripts/get_token.sh`
Decrypts and prints a customer's gateway token.

```bash
TOKEN_ENCRYPTION_KEY=<key> ./scripts/get_token.sh <subdomain>
```

**Example:**
```bash
TOKEN_ENCRYPTION_KEY="$TOKEN_ENCRYPTION_KEY" ./scripts/get_token.sh acme-corp
```

### `scripts/setup-server.sh`
Runs on the remote server over SSH during provisioning. Installs OpenClaw, configures nginx, sets up the firewall, and verifies gateway authentication. Called automatically by `provision.sh` — not meant to be run directly.

### `scripts/lib/provider.sh`
DigitalOcean API abstraction. Exports `provider_create`, `provider_is_ready`, `provider_get_status`, and `provider_delete`. Sourced by `provision.sh` and `deprovision.sh`.

### `scripts/lib/retry.sh`
Generic retry/poll helper. `retry <max_seconds> <interval> <command...>` runs a command repeatedly until it succeeds or the timeout is reached. Sourced by `provision.sh`.

## Key Generation

Generate a `TOKEN_ENCRYPTION_KEY`:
```bash
openssl rand -hex 32
```

Store it somewhere safe (e.g., 1Password, AWS Secrets Manager, or a `.env` file with `chmod 600` that is never committed).

## Token Storage

Customer gateway tokens are encrypted at rest using AES-256-CBC (PBKDF2, 100k iterations). The encrypted files live in `tokens/<subdomain>.token.enc` with `chmod 600`.

- Metadata (name, email, IP, server ID) → `customers.jsonl` (no credentials)
- Gateway tokens → `tokens/<subdomain>.token.enc` (encrypted, never plaintext)

## ⚠️ Status

This script is an MVP prototype. See open issues for known security and reliability gaps before using in production.

## Repos

- Website: [lookgugu/Hosted-claw.com](https://github.com/lookgugu/Hosted-claw.com)
- Ops (this repo): `lookgugu/hosted-claw-ops`
