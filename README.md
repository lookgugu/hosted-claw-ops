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

## ⚠️ Status

This script is an MVP prototype. See open issues for known security and reliability gaps before using in production.

## Repos

- Website: [lookgugu/Hosted-claw.com](https://github.com/lookgugu/Hosted-claw.com)
- Ops (this repo): `lookgugu/hosted-claw-ops`
