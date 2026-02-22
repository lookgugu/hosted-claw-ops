# hosted-claw-ops

Deployment and operations scripts for [Hosted Claw](https://hosted-claw.com) — managed [OpenClaw](https://github.com/nicholasgasior/openclaw) hosting.

## Prerequisites

- Bash 4+
- [jq](https://jqlang.github.io/jq/)
- [curl](https://curl.se/)
- `ssh` and `ssh-keyscan`
- `openssl`
- A [Hetzner Cloud](https://www.hetzner.com/cloud) account with an API token and registered SSH key

## Setup

Export your credentials before running any scripts:

```bash
export HETZNER_API_TOKEN="your-api-token"        # Read + Write permissions
export HETZNER_SSH_KEY_ID="your-ssh-key-id"      # SSH key registered in Hetzner
export TOKEN_ENCRYPTION_KEY="$(openssl rand -hex 32)"  # For encrypting gateway tokens
```

Store `TOKEN_ENCRYPTION_KEY` somewhere safe (e.g., 1Password, AWS Secrets Manager, or a `.env` file with `chmod 600` that is never committed).

## Scripts

### `scripts/provision.sh`

Provisions a new customer OpenClaw instance on Hetzner Cloud.

```bash
./scripts/provision.sh customer@email.com "Customer Name"
```

This will:

1. Validate the email, customer name, and env vars
2. Generate a gateway auth token
3. Create a Hetzner CX11 VPS (Ubuntu 22.04, Nuremberg region)
4. Poll the Hetzner API until the server is running
5. Verify the SSH host key and add it to `~/.ssh/known_hosts`
6. Install Node.js 22 (signed APT repo), OpenClaw, nginx, certbot, and UFW over SSH
7. Configure gateway auth token and verify it's enforced
8. Configure nginx as a reverse proxy at `<subdomain>.hosted-claw.com`
9. Attempt SSL certificate issuance via certbot
10. Verify auth is enforced from the external network
11. Save customer metadata to `customers.jsonl` (no credentials)
12. Encrypt and store the gateway token in `tokens/`
13. Print a ready-to-send welcome email template

If provisioning fails after the VPS is created, the script automatically deletes the server to avoid orphaned billing.

### `scripts/get_token.sh`

Decrypts and prints a customer's gateway token.

```bash
TOKEN_ENCRYPTION_KEY=<key> ./scripts/get_token.sh <subdomain>
```

## Token storage

Customer gateway tokens are encrypted at rest using AES-256-CBC (PBKDF2, 100k iterations). The encrypted files live in `tokens/<subdomain>.token.enc` with `chmod 600`.

- Metadata (name, email, IP, server ID) -> `customers.jsonl` (no credentials)
- Gateway tokens -> `tokens/<subdomain>.token.enc` (encrypted, never plaintext)

## What gets installed on each VPS

| Component | Details |
|-----------|---------|
| OS | Ubuntu 22.04 |
| Node.js | v22 via signed NodeSource APT repo |
| OpenClaw | Latest, running as `openclaw` system user |
| Gateway | `openclaw-gateway@openclaw` systemd service on port 18789 (token-authenticated) |
| Nginx | Reverse proxy with customer subdomain and forwarding headers |
| SSL | Certbot with nginx plugin (requires DNS to be configured first) |
| Firewall | UFW allowing ports 22, 80, 443 only; port 18789 denied externally |

## Project structure

```
.
├── .github/workflows/
│   └── lint.yml             # ShellCheck CI on push/PR to main
├── docs/
│   └── provisioning-flow.md # Detailed flow review and known issues
├── scripts/
│   ├── provision.sh         # Customer provisioning script
│   └── get_token.sh         # Token decryption helper
├── .gitignore               # Excludes customers.jsonl, tokens/, .env, keys, logs
└── README.md
```

## Post-provisioning steps

After running the script:

1. Send the welcome email (template is printed by the script)
2. Point `<subdomain>.hosted-claw.com` DNS to the server IP
3. SSH in and run `certbot --nginx` if it didn't succeed during provisioning
4. Add the dashboard URL to UptimeRobot
5. Schedule a follow-up check-in with the customer

## Related repos

- **Website**: [lookgugu/Hosted-claw.com](https://github.com/lookgugu/Hosted-claw.com)
- **Ops (this repo)**: [lookgugu/hosted-claw-ops](https://github.com/lookgugu/hosted-claw-ops)
