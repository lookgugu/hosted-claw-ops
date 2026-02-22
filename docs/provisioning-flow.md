# Provisioning Flow — Review & Documentation

> Review of `scripts/provision.sh` covering the end-to-end customer
> provisioning pipeline, known issues, and recommendations.

---

## 1. Flow overview

```
Operator workstation                          Hetzner Cloud
========================                      ==============

 1. Validate inputs
    (email, name, env vars incl.
     TOKEN_ENCRYPTION_KEY)
            │
 2. Generate gateway auth token
            │
 3. POST /v1/servers ──────────────────────►  Create CX11 VPS
    (HTTP status code verified)               (Ubuntu 22.04, nbg1)
            │
 4. Poll GET /v1/servers/{id} ◄──────────────  status → running
            │
 5. ssh-keyscan ◄──────────────────────────── Fetch host key
    ssh-keygen -R (dedup known_hosts)
            │
 6. SSH root@IP ─────────────────────────────►
    ├─ apt-get update
    ├─ Install Node.js 22 (signed NodeSource APT repo)
    ├─ npm install -g openclaw@latest
    ├─ useradd openclaw
    ├─ openclaw onboard --install-daemon
    ├─ Configure gateway auth token
    ├─ systemctl enable/start gateway
    ├─ Verify auth (expect 401 on unauthenticated)
    ├─ Install nginx + certbot
    ├─ Write nginx reverse-proxy config (subdomain + headers)
    ├─ ufw allow 22/80/443, deny 18789
    └─ certbot (may fail — DNS not ready)
            │
 7. Verify auth from external network (expect 401)
 8. Check for TLS cert → set dashboard URL
    (https:// if cert exists, http:// otherwise)
 9. Save customer metadata to customers.jsonl
10. Encrypt gateway token → tokens/<subdomain>.token.enc
11. Print welcome email template
```

If any step after server creation fails, an `EXIT` trap deletes the
VPS to avoid orphaned billing. The trap is cleared after remote install
succeeds.

---

## 2. Phase-by-phase detail

### Phase 1 — Input validation

| Check | Rule |
|-------|------|
| Positional args | Both `$1` (email) and `$2` (name) required |
| Email format | Regex via `grep -qE` |
| Customer name | Sanitized to lowercase alphanumeric + hyphens for subdomain |
| `HETZNER_API_TOKEN` | Must be non-empty |
| `HETZNER_SSH_KEY_ID` | Must be non-empty |
| `TOKEN_ENCRYPTION_KEY` | Must be non-empty |

The customer **subdomain** is derived from the name by lower-casing,
replacing spaces with hyphens, and stripping non-alphanumeric characters.

### Phase 2 — Credential generation

- Gateway token generated with `openssl rand -hex 32` before VPS creation.
- Token is passed to the remote server via unquoted heredoc expansion.

### Phase 3 — VPS creation

- JSON payload built safely with `jq -n` (no shell interpolation in JSON).
- HTTP status code is verified (non-2xx causes early exit with error detail).
- Server type: `cx11` (shared vCPU, 2 GB RAM).
- Location: `nbg1` (Nuremberg).
- Hetzner labels store `customer_email` and `service: hosted-claw`.
- Server ID is extracted and validated.

### Phase 4 — Boot polling

- Polls `GET /v1/servers/{id}` every 5 s, up to 180 s.
- Breaks when `status == "running"` and IPv4 is available.

### Phase 5 — SSH readiness

- Any stale `known_hosts` entry for the IP is removed via `ssh-keygen -R`.
- `ssh-keyscan -T 10` retried up to 10 times (100 s total).
- Host key stored in a shell variable and appended to `~/.ssh/known_hosts`.

### Phase 6 — Remote installation

Runs as a single SSH session under `root@$SERVER_IP`:

1. System update (`apt-get update`).
2. Node.js 22 via **signed NodeSource APT repository** (not `curl|bash`).
3. `npm install -g openclaw@latest`.
4. Dedicated `openclaw` user created.
5. `openclaw onboard --install-daemon` run as `openclaw` user — configures
   `anthropic/claude-sonnet-4-5` model and gateway on port 18789.
6. Gateway auth token configured via `openclaw config patch`.
7. `systemctl enable/start openclaw-gateway@openclaw`.
8. Auth verified internally (expect HTTP 401 on unauthenticated request).
9. Nginx installed, configured as reverse proxy for
   `<subdomain>.hosted-claw.com` with X-Real-IP, X-Forwarded-For,
   X-Forwarded-Proto headers. Default site removed.
10. UFW firewall: ports 22, 80, 443 allowed; port 18789 denied.
11. Certbot attempts SSL — **expected to fail** unless DNS is pre-configured.
    The script checks for the certificate file afterward to determine whether
    TLS is active.

### Phase 7 — Post-install verification and bookkeeping

- Auth is verified from the external network (expect 401).
- Dashboard URL is set to `https://` if the certbot certificate exists on the
  server, otherwise falls back to `http://` with a warning.
- Customer metadata saved to `customers.jsonl` via `jq` (no credentials).
- Gateway token encrypted with AES-256-CBC (PBKDF2, 100k iterations) and
  stored in `tokens/<subdomain>.token.enc`.
- Welcome email template printed to stdout.

---

## 3. Issues found

### Bugs

| # | Severity | Description |
|---|----------|-------------|
| B1 | **Medium** | **Nginx `server_name` relies on heredoc expansion ordering.** The outer `<< ENDSSH` is unquoted so `${CUSTOMER_SUBDOMAIN}` expands locally before being sent to the remote shell — this works, but only because the outer heredoc is unquoted. If someone quotes it (`<< 'ENDSSH'`) for other reasons, the nginx config will contain a literal `${CUSTOMER_SUBDOMAIN}`. |

### Security

| # | Severity | Description |
|---|----------|-------------|
| S1 | **Medium** | **Trust-on-first-use (TOFU) host key.** `ssh-keyscan` blindly trusts whatever key the IP returns. Acceptable for a just-created server, but a network-level attacker could intercept. Hetzner's API does not currently return host keys, so there is no easy fix, but the risk should be documented. |
| S2 | **Medium** | **All remote work runs as root.** No post-provision SSH hardening (disable password auth, disable root login, create an ops user). |
| S3 | **Low** | **`npm install -g` runs as root.** A compromised npm package gets full root execution. Consider installing as a non-root user or using a Node version manager. |

### Reliability

| # | Severity | Description |
|---|----------|-------------|
| R1 | **High** | **No duplicate/collision check.** Running the script twice for the same customer name creates a second VPS (or fails with a Hetzner name collision, with a confusing error). |
| R2 | **Medium** | **Certbot always fails on first run.** DNS can't point to a server that didn't exist a minute ago (unless wildcard DNS is pre-configured). Dashboard URL now correctly falls back to HTTP when this happens. |

---

## 4. Recommendations

### Must fix (before onboarding real customers)

1. **Add a duplicate guard.** Before calling the Hetzner API, query
   `GET /v1/servers?name=hosted-claw-<subdomain>` and abort if one exists.

2. **Expand the cleanup trap to cover signals.** Add `INT TERM` to the trap
   so Ctrl+C doesn't orphan a half-built server.

### Should fix

3. **Harden SSH after install.** Append to the remote SSH session:
   ```bash
   sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
   sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
   systemctl reload sshd
   ```

4. **Automate DNS.** If using Cloudflare or another API-driven DNS provider,
   add an A-record step before the certbot call so SSL succeeds on first run.

### Nice to have

5. **Idempotent re-run.** Accept a `--server-id` flag to skip creation and
   re-run only the install phase on an existing server.

6. **Structured logging.** Write a JSON log of each provision (server ID, IP,
   timing, success/failure) for audit and debugging.

7. **`--dry-run` flag.** Validate inputs and print the API payload without
   making any calls.

---

## 5. Environment & CI

- **ShellCheck** runs on every push/PR to `main` via
  `.github/workflows/lint.yml` (GitHub Actions).
- Secrets (`customers.jsonl`, `tokens/`, `.env`, SSH keys) are git-ignored.
