# Hosted Claw — Fulfillment Engine Architecture & Roadmap

## Context

`hosted-claw.com` sells managed AI-agent hosting. When a customer signs up and pays, they
should get their own isolated agent instance, on demand, on DigitalOcean.

This repo (`hosted-claw-ops`) is the **fulfillment engine**: the system that turns a paid
signup into a running, reachable, per-user agent — and manages that instance's whole
lifecycle (create, route, scale, suspend, destroy).

**Today** the `main` branch is a **434-line Bash MVP** that does something materially
different from the stated goal:

- Installs the **`openclaw` npm package** (`scripts/provision.sh:175`), not **Hermes Agent**.
- Provisions **one full Hetzner `cx11` VPS per customer** (`scripts/provision.sh:69`), not a
  Docker container.
- Each instance is **always-on**, with **no scale up/down**.
- Provisioning is a **manual CLI run** (`scripts/provision.sh customer@email "Name"`); there
  is **no control plane, no API, no billing hook, no real database**. State lives in
  `customers.jsonl` (metadata) + AES-256-CBC token files (`scripts/get_token.sh`).
- TLS is a **self-signed cert per VPS** behind nginx (`scripts/provision.sh:206-280`).

An **in-flight branch — `claude/migrate-to-digitalocean-whLYF` —** already ports the provider
from Hetzner to **DigitalOcean droplets** and refactors the monolithic Bash into reusable
modules. It is the foundation for everything below and should be **merged first** (see Phase 0):

| Module | Responsibility |
| --- | --- |
| `scripts/lib/provider.sh` | DO droplet create / poll-until-ready / delete |
| `scripts/lib/retry.sh` | Generic `retry <max> <interval> <cmd…>` poll helper |
| `scripts/lib/customers.sh` | `customers.jsonl` CRUD via `jq` (add/find/remove) |
| `scripts/setup-server.sh` | Remote install logic, piped over SSH |
| `scripts/deprovision.sh` | Teardown: delete droplet, remove record + token |

**Decisions taken for this plan** (from the user):

1. Re-target the product from OpenClaw → **NousResearch Hermes Agent** (Python, ships a
   Dockerfile + docker-compose, MIT licensed).
2. Isolation model = **one Docker container per user**, packed onto shared DO droplets.
3. Scaling (always-on vs scale-to-zero) is **an open design question** — options below, no
   hard commitment.
4. Deliverable = **architecture blueprint + phased roadmap** ("where to start").

This document is a blueprint, not an implementation. No engine code is written here.

---

## Target Architecture

Two planes plus an ingress layer:

```
                 hosted-claw.com (separate repo)
                   │  Stripe checkout / signup
                   ▼  webhook (purchase, cancel)
        ┌───────────────────────────────────────────┐
        │            CONTROL PLANE (this repo)        │
        │  API (FastAPI)  ·  Worker/queue  ·  Postgres │
        │  provision / suspend / resume / destroy      │
        │  placement · secrets · per-user state record │
        └───────────────┬─────────────────────────────┘
                         │ Docker API over TLS / SSH
                         ▼
   ┌─────────────────────────────────────────────────────────┐
   │              DATA PLANE: DO droplet fleet (Docker)         │
   │  host-1: [hermes:userA] [hermes:userB] ...                │
   │  host-2: [hermes:userC] [hermes:userD] ...                │
   │  each container: own HERMES_HOME volume, CPU/mem limits   │
   └─────────────────────────────────────────────────────────┘
                         ▲
                         │  *.hosted-claw.com  (wildcard DNS)
        ┌────────────────┴───────────────┐
        │  INGRESS: Traefik / Caddy        │
        │  subdomain → container routing   │
        │  automatic Let's Encrypt certs   │
        └──────────────────────────────────┘
```

### Control plane (the new core of this repo)

- **API service** — receives provisioning intents from `hosted-claw.com` (Stripe webhook on
  purchase; cancel/refund → suspend/destroy). Idempotent, async.
- **Worker + queue** — runs the slow lifecycle jobs (pull image, create volume, start
  container, register route, issue cert). Decouples webhook latency from provisioning time.
  RQ or Celery + Redis.
- **Postgres** — replaces `customers.jsonl`. Tables: `users`; `instances` (user_id, host_id,
  container_id, subdomain, plan, status, last_active_at); `hosts` (droplet id, capacity,
  current load). Source of truth for placement and billing reconciliation.
- **Secrets** — per-user gateway token + model API keys. Move off local AES files to a managed
  store (DO has no native one — options: HashiCorp Vault, SOPS-encrypted secrets, or
  Doppler/1Password). Injected into containers as env at start, never baked into images.

### Data plane (agent hosts)

- A **fleet of DO droplets** running Docker, labeled "agent hosts." Reuse the droplet
  create/poll/delete logic from `scripts/lib/provider.sh` — but for *host* lifecycle, not
  per-customer.
- **Per-user Hermes container** built from the upstream `hermes-agent` Dockerfile, pinned to a
  vetted version. Each container gets:
  - its own **volume** mounted at `~/.hermes` (SQLite `state.db`, `config.yaml`, skills,
    memory) — the per-user persistent state;
  - **CPU/memory limits** by plan tier (Hermes needs low-GB RAM with a cloud model backend; no
    GPU, since it calls model APIs);
  - injected env: gateway token, model provider key, `HERMES_UID/GID`.
- **Placement**: control plane bin-packs containers onto hosts by capacity; scale the host
  fleet when utilization crosses thresholds.

### Ingress & routing

- **Wildcard DNS** `*.hosted-claw.com` → ingress (DO DNS API for records).
- **Traefik or Caddy** as the dynamic reverse proxy: maps `<user>.hosted-claw.com` → the
  correct container/host, terminates TLS, and **auto-issues real Let's Encrypt certs**
  (replacing today's self-signed-cert-per-VPS). Far better fit for container-per-user than the
  current per-VPS nginx.

---

## Key Decisions & Tradeoffs

### 1. Isolation risk (highest-priority caveat)

Hermes Agent **executes terminal commands, code, and browser automation as a core feature**.
Running many users' code-executing agents as **plain Docker containers on a shared host** means
a container escape = cross-tenant compromise. Plain namespaces are not a strong security
boundary for hostile/code-running workloads.

Mitigation ladder (build into the roadmap, don't bolt on later):

- **Baseline:** rootless containers, seccomp/AppArmor profiles, drop capabilities, **no Docker
  socket in containers**, read-only root fs where possible, strict egress controls, resource limits.
- **Strong:** run containers under **gVisor (runsc)** or **Kata Containers** (microVM per
  container) for kernel-level isolation. This is the realistic answer for multi-tenant agent
  code execution.
- Note: per-user droplets (today's model) are *more* isolated. The container-per-user choice
  trades isolation for density/cost — gVisor/Kata buys back most of the safety. If strong
  isolation is paramount, microVM platforms (Firecracker / Fly Machines style) are the safer
  analog to "container per user."

### 2. Scaling — OPEN QUESTION (present, don't hard-commit)

- **Always-on, right-sized (simplest):** each user's container runs continuously; "scale" =
  pick container resource limits per plan tier. Lowest complexity, predictable cost, no cold
  starts. Cost floor per idle user.
- **Scale-to-zero (cheapest at idle):** stop idle containers (detect via gateway inactivity /
  `last_active_at`), persist the volume, and **resume on demand** — a wake proxy at ingress
  holds the first request, asks the control plane to start the container, then forwards once
  healthy. Big idle savings; adds cold-start latency + wake machinery.
- **Recommendation:** ship **always-on** first (Phases 1–4), instrument `last_active_at`, then
  add **scale-to-zero** in Phase 5 once real idle data justifies the complexity.

### 3. Control-plane stack

Recommend **Python + FastAPI** (API), a lightweight queue/worker (RQ or Celery + Redis), and
**Postgres**. Rationale: aligns with Hermes' Python ecosystem (shared tooling/skills), strong
Docker SDK, fast to build. (Node/TypeScript is a fine alternative if the website team prefers
one language across repos — flag this as a team choice.)

### 4. Orchestration: build-your-own vs Kubernetes

User chose plain **Docker-per-user over DOKS**. Honor that: control plane manages Docker
directly via the Docker Engine API. Keep **DOKS / Nomad as the documented evolution** for when
host count and placement complexity outgrow a hand-rolled scheduler.

---

## Reuse From Current Repo

All modules below already exist on `claude/migrate-to-digitalocean-whLYF`:

- **`scripts/lib/provider.sh`** — droplet create/poll/delete; repurpose for **host fleet**
  lifecycle.
- **`scripts/lib/retry.sh`** — generic poll/retry; reusable in worker jobs.
- **`scripts/lib/customers.sh`** — JSONL add/find/remove; maps directly onto the Postgres
  `instances` repository layer (same fields).
- **`scripts/setup-server.sh`** — remote install logic; the **seed for the Hermes container
  image build** (swap `openclaw`→`hermes`, drop the per-host nginx in favour of ingress).
- **`scripts/deprovision.sh`** — droplet + record + token teardown; the **seed for the
  control-plane `destroy` path**.
- **Token encryption pattern** (`scripts/get_token.sh`, AES-256-CBC) — interim secrets approach
  until a managed store lands.
- **`customers.jsonl` record shape** — maps onto the Postgres `instances` schema.

---

## Phased Roadmap — "Where to Start"

Tracer-bullet: get one real instance reachable end-to-end before building the control plane
around it.

- **Phase 0 — Land the foundation + de-risk Hermes.**
  (a) **Merge `claude/migrate-to-digitalocean-whLYF`** so DO provider, `deprovision.sh`, and the
  `lib/` refactor are the Bash baseline.
  (b) **Hermes spike:** manually run **one Hermes container** on a single DO droplet; reach the
  dashboard over HTTPS with a real cert; confirm a chat round-trip against a model API.
  → *verify:* dashboard loads, agent responds, and you've measured the container's real
  CPU/mem/disk footprint and confirmed required env vars + dashboard port/auth model.
- **Phase 1 — Per-user image & runtime contract.** Build a pinned `hosted-claw/hermes` image
  from upstream; define parameterization (HERMES_HOME volume, injected token + model key,
  resource limits) and a baseline security profile (seccomp, dropped caps, no docker socket).
  → *verify:* two containers on one host stay fully isolated (separate state, can't see each
  other), survive restart with state intact.
- **Phase 2 — Ingress & routing.** Stand up Traefik/Caddy on an ingress droplet; wildcard DNS;
  per-subdomain auto Let's Encrypt; route `<user>.hosted-claw.com` → the right container.
  (Closes **issue #8**.) → *verify:* two users on valid HTTPS subdomains, no cross-routing,
  certs auto-issued.
- **Phase 3 — Control-plane MVP.** FastAPI + Postgres + worker. Endpoints: `provision`,
  `destroy` (single host first). Replaces `provision.sh` + `customers.jsonl`; wires in the
  secrets store, registers routes with ingress, and writes a structured audit log
  (**issue #12**). The `destroy` path reuses `deprovision.sh` logic (**issue #11**).
  → *verify:* one API call provisions a working, reachable instance end-to-end; `destroy`
  fully cleans up (container, volume, route, DNS).
- **Phase 4 — Signup integration.** Stripe webhook from `hosted-claw.com` → `provision`;
  cancel/refund → suspend/destroy. Idempotent, retried, reconciled against Postgres.
  → *verify:* a test-mode Stripe purchase produces a live instance; cancellation tears it down.
- **Phase 5 — Multi-host scale + scaling model.** Host-fleet management, placement/bin-packing,
  autoscale hosts on utilization; then implement the chosen scaling model (recommend adding
  **scale-to-zero** here, driven by `last_active_at` + a wake proxy). → *verify:* fleet scales
  under simulated load; idle instances suspend and resume on next request.
- **Phase 6 — Hardening & ops.** Strong isolation (**gVisor/Kata**), observability
  (metrics/logs/alerts per instance + fleet, **issue #10**), per-user volume backups
  (**issue #9**), quotas/rate limits, audit logging. → *verify:* container-escape attempt
  contained; instance recoverable from backup.

---

## Open-Issue Mapping

The 9 open issues map cleanly onto the phases above:

| Issue | Summary | Phase |
| --- | --- | --- |
| #3 | `StrictHostKeyChecking=no` MITM | Already fixed on `main` (ssh-keyscan) / P0 |
| #5 | Input sanitization | Largely handled by DO branch (`jq -n --arg`) / P0 |
| #6 | API response validation | Handled by DO branch / P0 |
| #7 | Retry, rollback, cleanup on failure | DO branch (`retry.sh`, trap) / P0 |
| #8 | Automate TLS + DNS, branded subdomains | **Phase 2** (ingress + wildcard DNS + LE) |
| #11 | Deprovisioning / lifecycle (suspend/resume) | **Phase 3** (`destroy`) + **Phase 4** (Stripe) |
| #12 | Audit trail / structured log | **Phase 3** (Postgres + structured logs) |
| #9 | Backup strategy | **Phase 6** (per-volume backups) |
| #10 | Monitoring & health checks | **Phase 6** (observability) |

---

## End-to-End Verification (once Phases 0–4 land)

1. Trigger a test-mode Stripe purchase on `hosted-claw.com`.
2. Confirm the webhook hits the control plane and a worker job runs to completion.
3. Confirm a Hermes container starts on an agent host with an isolated volume + injected secrets.
4. Visit `<user>.hosted-claw.com` over HTTPS (valid cert), authenticate, complete a chat round-trip.
5. Confirm the Postgres `instances` row reflects status/placement.
6. Cancel the subscription; confirm the instance is suspended/destroyed and resources reclaimed.

---

## Open Questions To Resolve Before Building

- **Scaling model** (always-on vs scale-to-zero) — recommend always-on first, revisit in Phase 5.
- **OpenClaw → Hermes confirmation** — confirm the upstream Hermes Dockerfile + dashboard
  port/auth model in the Phase 0 spike (some details came from web research and need first-hand
  verification).
- **Secrets store** choice (Vault / SOPS / Doppler / 1Password) — pick before Phase 3.
- **Control-plane language** (Python/FastAPI recommended vs Node, to match the website repo).
- **Isolation target** — is gVisor/Kata a launch requirement or a fast-follow? (Drives Phase 1
  vs Phase 6 effort.)
- **Custom domains / subdomain scheme** — `<user>.hosted-claw.com` slug rules, collisions, renames.
