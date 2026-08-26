# Private-LB starter-hub overlay

Provisions a Scion starter hub for a project subject to hardening / org-policy
constraints, using a hardened topology that differs from the stock
single-public-VM path:

- a **custom VPC** with a subnet that has Private Google Access;
- a **private VM** (no external IP) whose egress goes through **Cloud NAT**;
- a **global external HTTPS load balancer** that terminates client TLS with a
  **Google-managed certificate** and **re-encrypts to Caddy** on the VM over
  `:443` ("double TLS"); Caddy serves its Let's Encrypt cert and reverse-proxies
  to the hub on `:8080`;
- agents run as **Docker containers on the hub VM** (no GKE broker).

The overlay is additive: it sets the opt-in variables already defined in
[`../hub-config.sh`](../hub-config.sh) and adds three net-new provisioning steps
(network, load balancer, hub-env-from-Secret-Manager). The stock scripts remain
fully backward-compatible — with none of these variables set they behave exactly
as before.

## Topology

```
                         Internet
                            │  https://scion.hub.<domain>
                            ▼
              ┌──────────────────────────────┐
              │  Global external HTTPS LB     │
              │  - static global IP           │
              │  - Google-managed TLS cert    │
              │  - URL map → backend service  │
              └──────────────┬───────────────┘
                             │  HTTPS :443  (GCLB ranges only)
                             ▼
      Custom VPC (scion-network / scion-subnet, PGA on)
              ┌──────────────────────────────┐
              │  Private VM  (no public IP)   │
              │  - Caddy :443 (Let's Encrypt) │
              │      └─ reverse_proxy :8080   │
              │  - scion hub (systemd)        │
              │  - Docker: agent containers   │
              └───────┬───────────────┬───────┘
                      │ egress        │ SSH
                      ▼               ▼
                 Cloud NAT       IAP tunnel (35.235.240.0/20)
```

## Stock vs. private-LB (what changes and why)

| Concern            | Stock starter-hub                        | Private-LB overlay                                         | Why |
|--------------------|------------------------------------------|------------------------------------------------------------|-----|
| Network            | `default` VPC                            | custom VPC + subnet (Private Google Access)                 | Sandbox isolation; no reliance on the default network |
| VM exposure        | public IP                                | **no external IP**; egress via Cloud NAT                    | Smaller attack surface; org policy often forbids public IPs |
| SSH                | direct                                   | `--tunnel-through-iap`                                      | Private VM is reachable only through IAP |
| TLS                | Caddy + Let's Encrypt on the VM          | LB **Google-managed cert** (client side) **+ Caddy/Let's Encrypt on the VM** (LB re-encrypts — "double TLS") | Managed cert for browsers; the LB→VM hop stays encrypted too |
| Ingress firewall   | `tcp:80,443` from anywhere               | `tcp:443,8080` from GCLB ranges + `tcp:22` from IAP range   | LB traffic → `:443` (Caddy); LB health check → `:8080` (hub); IAP → `:22` |
| DNS                | A record → VM IP (by `gce-certs.sh`)     | A record → **LB static IP** (by `lb.sh`)                   | Traffic terminates at the LB, not the VM |
| Agent runtime      | GKE (optional) or Docker                 | **Docker on the VM** (`ENABLE_GKE=false`)                  | GKE removed — simpler, fewer moving parts |
| Admin console      | admins / telemetry / updates unconfigured | pre-seeds `server.hub.admin_emails`, `telemetry.cloud.gcp_project_id`, `SCION_MAINTENANCE_REPO_PATH` | Admin UI visible, metrics dashboard initialized, and "check for updates" work immediately after a rebuild |
| Telemetry SA key   | downloads a JSON key                      | **keyless-tolerant** — falls back to ADC if the org policy forbids SA keys | Some organization policies enforce `constraints/iam.disableServiceAccountKeyCreation` |

## Files

| File            | Role |
|-----------------|------|
| `config.sh`     | Sourced preset: sets the opt-in vars, then sources `../hub-config.sh`. |
| `network.sh`    | Create/delete custom VPC, subnet, Cloud Router, Cloud NAT. |
| `lb.sh`         | Create/delete the HTTPS LB chain + DNS; waits for the managed cert. |
| `hubenv.sh`     | Generate the hub env file from Secret Manager (secrets never printed). |
| `deploy.sh`     | Orchestrator: `deploy` and `delete [--release-ip]`. |
| `env.sample`    | Optional non-secret overrides. |

## Prerequisites

- `gcloud` authenticated against the target project; `git`, `openssl` installed.
- A Cloud DNS **managed zone** hosting the hub domain (`DNS_ZONE_NAME`).
- OAuth credentials stored in **Secret Manager** (Google web + CLI clients):
  - `scion-hub-oauth-web-client-id`, `scion-hub-oauth-web-client-secret`
  - `scion-hub-oauth-cli-client-id`, `scion-hub-oauth-cli-client-secret`
- A GCS bucket for hub storage (defaults to `<project>-scion-hub`).

## Usage

Run from the repository root:

```bash
# Full deploy
scripts/starter-hub/private-lb/deploy.sh

# Tear down but KEEP the static IP, DNS record, GCS bucket, and OAuth secrets
# (so the URL survives a rebuild)
scripts/starter-hub/private-lb/deploy.sh delete

# Tear down and also release the static IP + remove the DNS record
scripts/starter-hub/private-lb/deploy.sh delete --release-ip
```

Individual steps can be run on their own (each sources `config.sh`):

```bash
scripts/starter-hub/private-lb/network.sh          # or: ... delete
scripts/starter-hub/private-lb/hubenv.sh
scripts/starter-hub/private-lb/lb.sh               # or: ... delete [--release-ip]
```

## Secrets

No secret value is ever committed or printed. `hubenv.sh` reads OAuth
client IDs/secrets from Secret Manager at deploy time and writes them to
`.scratch/hub-<name>.env` (mode `600`, gitignored). `SESSION_SECRET` is reused
from an existing env file or generated with `openssl` if absent.

## Admin console & telemetry

A from-scratch rebuild otherwise leaves three admin-console features unconfigured
(the hub only reads these from its `settings.yaml` / `hub.env`, which stock
provisioning never wrote). The overlay pre-seeds them so the console works
immediately:

| Feature | Key emitted | Source var | Effect |
|---------|-------------|-----------|--------|
| Admin access | `server.hub.admin_emails` (settings.yaml) | `HUB_ADMIN_EMAILS` (defaults to `admin@example.com`) | Listed accounts are reconciled to the `admin` role on every OAuth login, so the admin console is visible |
| Metrics dashboard | `telemetry.cloud.gcp_project_id` (settings.yaml) | `PROJECT_ID` | The hub initializes its metrics dashboard instead of returning `503 metrics_unavailable` |
| Check for updates | `SCION_MAINTENANCE_REPO_PATH` (hub.env) | `REPO_DIR` (`/home/scion/scion`) | The console can `git fetch` and compare `HEAD` vs `origin/main` instead of erroring `No repository path configured` |

Override the admins via `HUB_ADMIN_EMAILS` (comma-separated) in
[`env.sample`](env.sample). Both settings.yaml blocks are
conditional: with their source vars empty the generated file is byte-identical to
the stock hub settings, so non-overlay deployments are unaffected.

**Keyless telemetry SA.** Some organization policies enforce
`constraints/iam.disableServiceAccountKeyCreation`, which forbids downloading
service-account keys. `gce-demo-telemetry-sa.sh` (deploy Step 3) tolerates this:
it still creates the SA and grants the telemetry roles, but if key creation is
denied it degrades to **keyless** (consume the SA via Application Default
Credentials — the VM's attached SA / Workload Identity — and rely on
`SCION_GCP_PROJECT_ID`, which the hub env already sets). Force it explicitly with
`TELEMETRY_KEYLESS=true` to skip the (doomed) key attempt entirely.

## Notes

- **Double TLS:** clients terminate TLS at the LB (Google-managed cert); the LB
  re-encrypts to Caddy on the VM (`:443`, Let's Encrypt obtained by `gce-certs.sh`
  via a certbot DNS-01 challenge), and Caddy reverse-proxies to the hub on
  `:8080`. The LB health check hits the hub's `:8080` directly, so it does not
  depend on Caddy's host-based routing.
- The managed certificate can take **15–30+ minutes** to first become `ACTIVE`;
  `lb.sh` polls and then runs an end-to-end `https://<domain>/healthz`
  check.
- `gce-demo-preflight.sh` runs as a validation gate after the env file is
  generated. A few of its checks assume the stock Caddy/Let's Encrypt path (e.g.
  "DNS zone will be created by gce-certs.sh") and are safe to ignore here; set
  `SKIP_PREFLIGHT=true` to bypass it entirely.
