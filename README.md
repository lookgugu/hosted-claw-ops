# hosted-claw-ops

Deployment and operations scripts for [Hosted Claw](https://hosted-claw.com) — managed OpenClaw hosting.

## Scripts

### `scripts/provision.sh`
Provisions a new customer OpenClaw instance on Hetzner Cloud.

```bash
./scripts/provision.sh customer@email.com "Customer Name"
```

**Required env vars:**
- `HETZNER_API_TOKEN` — Hetzner Cloud API token (Read + Write)
- `HETZNER_SSH_KEY_ID` — SSH key ID registered in Hetzner
- `TOKEN_ENCRYPTION_KEY` — 32-byte hex key used to encrypt customer tokens at rest

Generate a key:
```bash
openssl rand -hex 32
```

Store it somewhere safe (e.g., 1Password, AWS Secrets Manager, or a `.env` file with `chmod 600` that is never committed).

### `scripts/get_token.sh`
Decrypts and prints a customer's gateway token.

```bash
TOKEN_ENCRYPTION_KEY=<key> ./scripts/get_token.sh <subdomain>
```

**Example:**
```bash
TOKEN_ENCRYPTION_KEY="$TOKEN_ENCRYPTION_KEY" ./scripts/get_token.sh acme-corp
```

## Token Storage

Customer gateway tokens are encrypted at rest using AES-256-CBC (PBKDF2, 100k iterations). The encrypted files live in `tokens/<subdomain>.token.enc` with `chmod 600`.

- Metadata (name, email, IP, server ID) → `customers.jsonl` (no credentials)
- Gateway tokens → `tokens/<subdomain>.token.enc` (encrypted, never plaintext)

## ⚠️ Status

This script is an MVP prototype. See open issues for known security and reliability gaps before using in production.

## Repos

- Website: [lookgugu/Hosted-claw.com](https://github.com/lookgugu/Hosted-claw.com)
- Ops (this repo): `lookgugu/hosted-claw-ops`
