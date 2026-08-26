#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# scripts/starter-hub/hub-config.sh - Shared configuration for all starter-hub scripts
#
# Set HUB_NAME before sourcing this file to parameterize all scripts for a
# specific deployment. For example:
#
#   export HUB_NAME=staging
#   ./scripts/starter-hub/gce-demo-deploy.sh
#
# All resource names, domains, and file paths are derived from HUB_NAME and
# BASE_DOMAIN. Override any individual variable via the environment if the
# derived default doesn't fit your setup.

# --- Primary Configuration ---
# HUB_NAME drives all resource naming. Defaults to "demo".
HUB_NAME="${HUB_NAME:-demo}"
BASE_DOMAIN="${BASE_DOMAIN:-scion-ai.dev}"

# --- Feature Flags ---
# Set to "false" to skip GKE cluster creation, credential setup, and
# container.admin IAM role. The hub will run with Docker as the default runtime.
ENABLE_GKE="${ENABLE_GKE:-false}"

# --- Derived: GCP Resources ---
INSTANCE_NAME="${INSTANCE_NAME:-scion-${HUB_NAME}}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-scion-${HUB_NAME}-sa}"
FIREWALL_RULE="${FIREWALL_RULE:-scion-${HUB_NAME}-allow-http-https}"
CLUSTER_NAME="${CLUSTER_NAME:-scion-${HUB_NAME}-cluster}"

# --- Derived: Domain & DNS ---
# CERT_DOMAIN is the zone used for wildcard certs (e.g., "demo.scion-ai.dev")
CERT_DOMAIN="${CERT_DOMAIN:-${HUB_NAME}.${BASE_DOMAIN}}"
# HUB_DOMAIN is the full hostname for the hub (e.g., "hub.demo.scion-ai.dev")
HUB_DOMAIN="${HUB_DOMAIN:-hub.${CERT_DOMAIN}}"
# DNS_ZONE_NAME is the Cloud DNS managed zone name (e.g., "demo-scion-ai-dev")
DNS_ZONE_NAME="${DNS_ZONE_NAME:-$(echo "${CERT_DOMAIN}" | tr '.' '-')}"

# --- Derived: Region / Zone ---
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"

# --- Derived: Project ---
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"

# --- Derived: Paths ---
HUB_ENV_FILE="${HUB_ENV_FILE:-.scratch/hub-${HUB_NAME}.env}"
REPO_DIR="${REPO_DIR:-/home/scion/scion}"
SCION_BIN="${SCION_BIN:-/usr/local/bin/scion}"

# --- Shared Defaults ---
GITHUB_REPO="${GITHUB_REPO:-GoogleCloudPlatform/scion}"
CERT_EMAIL="${CERT_EMAIL:-ptone@google.com}"
CLOUD_INIT_FILE="${CLOUD_INIT_FILE:-scripts/starter-hub/gce-demo-cloud-init.yaml}"

# --- Hub Admins ---
# Comma-separated list of Google account emails granted the hub "admin" role.
# determineUserRole() reconciles these to "admin" on every OAuth login (additive,
# never demoting), so the admin console (telemetry, maintenance, user management)
# is visible to them. Emitted into settings.yaml as server.hub.admin_emails by
# emit_settings_yaml (below). Empty by default (stock: no admins pre-seeded); a
# deployment overlay such as the private-LB preset sets it to its own admin(s).
HUB_ADMIN_EMAILS="${HUB_ADMIN_EMAILS:-}"

# SKIP_PUSH=true skips the local "git push origin" step in gce-start-hub.sh. The
# VM pulls the repo directly in its remote build session, so the local push is
# only useful when you are iterating on hub source in this checkout and want the
# VM to build your unpushed changes. Deployments whose origin is a read-only
# upstream (e.g. a deployment overlay tracking GoogleCloudPlatform/scion) should
# set this true. Defaults to false (stock behavior: push before the VM pulls).
SKIP_PUSH="${SKIP_PUSH:-false}"

# --- Advanced: Custom VPC, Private VM & External HTTPS Load Balancer ---
#
# These opt-in variables let a deployment run the hub on a custom VPC with a
# PRIVATE VM (no public IP, egress via Cloud NAT) fronted by a Google Cloud
# global external HTTPS load balancer that terminates client TLS with a
# Google-managed certificate and re-encrypts to Caddy on the VM — instead of the
# default public VM where Caddy alone terminates Let's Encrypt TLS.
#
# Every variable defaults to the original stock behavior, so existing public
# single-node deployments are completely unaffected when they are left unset.
# The private-LB overlay (scripts/starter-hub/private-lb/) sets these to reproduce
# this hardened topology; see that directory's README.md for the full mapping.

# Network placement. Defaults reproduce the stock "default network" behavior.
NETWORK="${NETWORK:-default}"
SUBNET="${SUBNET:-default}"
SUBNET_RANGE="${SUBNET_RANGE:-10.0.0.0/20}"

# VM_EXTERNAL_IP=false provisions the VM with no external IP (private VM).
# Requires Cloud NAT on the network for outbound access (see private-lb/network.sh).
VM_EXTERNAL_IP="${VM_EXTERNAL_IP:-true}"
ROUTER_NAME="${ROUTER_NAME:-scion-${HUB_NAME}-router}"
NAT_NAME="${NAT_NAME:-scion-${HUB_NAME}-nat}"

# SHIELDED_VM=true creates the VM as a Shielded VM (Secure Boot + vTPM +
# integrity monitoring). Some organization policies require this — they enforce
# constraints/compute.requireShieldedVm, which rejects a plain
# `instances create`. Defaults to false (stock behavior: no shielded flags, so
# the image/platform default applies).
SHIELDED_VM="${SHIELDED_VM:-false}"

# Extra flags appended to every `gcloud compute ssh`/`scp` call. A private VM
# (no external IP) is reachable only via IAP tunnelling, so set this to
# "--tunnel-through-iap". Empty by default (public VM, direct SSH).
SSH_TUNNEL_FLAG="${SSH_TUNNEL_FLAG:-}"

# ENABLE_LB=true fronts the hub with a global external HTTPS load balancer.
# When set: DNS points at the LB static IP (not the VM) and clients terminate TLS
# at the LB against a Google-managed certificate. The LB then RE-ENCRYPTS to the
# VM, connecting to Caddy (which serves its Let's Encrypt cert and reverse-proxies
# to the hub) over LB_BACKEND_PROTOCOL:LB_BACKEND_PORT ("double TLS"). The LB
# health check targets the hub's plain-HTTP port (LB_HC_PORT) directly, so it does
# not depend on Caddy's host-based routing.
ENABLE_LB="${ENABLE_LB:-false}"
HUB_PORT="${HUB_PORT:-8080}"
LB_BACKEND_PROTOCOL="${LB_BACKEND_PROTOCOL:-HTTPS}"
LB_BACKEND_PORT="${LB_BACKEND_PORT:-443}"
LB_HC_PORT="${LB_HC_PORT:-${HUB_PORT}}"
LB_IP_NAME="${LB_IP_NAME:-scion-${HUB_NAME}-lb-ip}"
LB_IG_NAME="${LB_IG_NAME:-scion-${HUB_NAME}-ig}"
LB_HC_NAME="${LB_HC_NAME:-scion-${HUB_NAME}-lb-http-hc}"
LB_BACKEND_NAME="${LB_BACKEND_NAME:-scion-${HUB_NAME}-backend}"
LB_URLMAP_NAME="${LB_URLMAP_NAME:-scion-${HUB_NAME}-urlmap}"
LB_CERT_NAME="${LB_CERT_NAME:-scion-${HUB_NAME}-sslcert}"
LB_PROXY_NAME="${LB_PROXY_NAME:-scion-${HUB_NAME}-target-proxy}"
LB_FORWARDING_RULE_NAME="${LB_FORWARDING_RULE_NAME:-scion-${HUB_NAME}-forwarding-rule}"

# --- Shared Helpers ---

# emit_settings_yaml — print the hub's settings.yaml (schema v1) to stdout.
#
# Kept as a pure, side-effect-free function (reads only the environment, writes
# only stdout) so it can be unit-tested in isolation — see
# starter-hub-config-test.sh. gce-start-hub.sh redirects it into the file it
# uploads to the VM.
#
# Two blocks are emitted CONDITIONALLY; when their inputs are empty the output is
# byte-identical to the original stock settings.yaml, so existing deployments are
# unaffected:
#   - server.hub.admin_emails   — only when HUB_ADMIN_EMAILS is non-empty. The
#       comma-separated list becomes a YAML sequence (entries trimmed). Without
#       it no user is reconciled to "admin" and the admin console stays hidden.
#   - telemetry.cloud.gcp_project_id — only when PROJECT_ID is non-empty. Without
#       it the hub cannot initialize the metrics dashboard (503
#       metrics_unavailable) and cloud trace/log export has no project to target.
#
# Inputs (environment): ENABLE_GKE, HUB_ADMIN_EMAILS, PROJECT_ID.
emit_settings_yaml() {
    local default_runtime="docker"
    [[ "${ENABLE_GKE:-}" == "true" ]] && default_runtime="kubernetes"

    # server.hub.admin_emails block (empty string when no admins configured).
    local admin_block=""
    if [[ -n "${HUB_ADMIN_EMAILS:-}" ]]; then
        admin_block=$'  hub:\n    admin_emails:\n'
        local _email _rest="${HUB_ADMIN_EMAILS}"
        local IFS=','
        for _email in ${_rest}; do
            # Trim leading/trailing whitespace around each comma-separated entry.
            _email="${_email#"${_email%%[![:space:]]*}"}"
            _email="${_email%"${_email##*[![:space:]]}"}"
            [[ -n "${_email}" ]] && admin_block+="      - ${_email}"$'\n'
        done
    fi

    # telemetry.cloud.gcp_project_id line (empty string when PROJECT_ID unset).
    local gcp_line=""
    [[ -n "${PROJECT_ID:-}" ]] && gcp_line=$'    gcp_project_id: "'"${PROJECT_ID}"$'"\n'

    cat <<SETTINGS_EOF
schema_version: "1"
default_runtime: ${default_runtime}
server:
  mode: production
${admin_block}telemetry:
  enabled: true
  cloud:
    enabled: true
    provider: "gcp"
    endpoint: "cloudtrace.googleapis.com:443"
    protocol: "grpc"
${gcp_line}    batch:
      max_size: 256
      timeout: "5s"
  local:
    enabled: true
  filter:
    events:
      exclude:
        - "agent.user.prompt"
    attributes:
      redact:
        - "prompt"
        - "user.email"
        - "tool_output"
        - "tool_input"
      hash:
        - "session_id"
SETTINGS_EOF
}

# Wait for the instance to be reachable via SSH and for cloud-init to finish.
# Call this before the first SSH-dependent step after provisioning.
wait_for_cloud_init() {
    echo "=== Waiting for VM to be ready (SSH + cloud-init) ==="
    local max_wait=600  # 10 minutes
    local interval=15
    local elapsed=0

    while (( elapsed < max_wait )); do
        local result
        # shellcheck disable=SC2086 # SSH_TUNNEL_FLAG is intentionally word-split (flag or empty)
        result=$(gcloud compute ssh "${INSTANCE_NAME}" \
            --project="${PROJECT_ID}" \
            --zone="${ZONE}" \
            ${SSH_TUNNEL_FLAG} \
            --ssh-flag="-o ConnectTimeout=10" \
            --command "cloud-init status 2>/dev/null || echo 'status: unknown'" \
            2>/dev/null) || result="SSH_UNREACHABLE"

        if [[ "$result" == "SSH_UNREACHABLE" ]]; then
            echo "  -> SSH not available yet... (${elapsed}s elapsed)"
        elif echo "$result" | grep -q "status: done"; then
            echo "  -> VM ready: cloud-init complete (${elapsed}s elapsed)"
            return 0
        elif echo "$result" | grep -q "status: error"; then
            echo "  -> Warning: cloud-init finished with errors (${elapsed}s elapsed)"
            echo "     Check: sudo cat /var/log/cloud-init-output.log"
            return 0
        else
            local status_text
            status_text=$(echo "$result" | head -1)
            echo "  -> SSH available, cloud-init: ${status_text} (${elapsed}s elapsed)"
        fi

        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done

    echo "Error: VM did not become ready after ${max_wait}s"
    return 1
}
