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

# scripts/starter-hub/private-lb/config.sh
#
# Private-LB overlay preset. SOURCE this file (do not execute it) to configure a
# starter-hub deployment for a project subject to hardening / org-policy
# constraints, reproducing this topology:
#
#   custom VPC + private VM (no public IP, egress via Cloud NAT)
#     + global external HTTPS load balancer (Google-managed client TLS cert)
#       that re-encrypts to Caddy (Let's Encrypt) on the VM ("double TLS")
#
# Agents run as Docker containers on the hub VM itself (the stock cloud-init
# installs Docker); there is no GKE broker (ENABLE_GKE=false).
#
# It sets the opt-in variables defined in ../hub-config.sh to the values that
# describe that topology, then sources ../hub-config.sh so every derived name
# and shared helper is available. All overrides are `export`ed so the stock
# scripts invoked as child processes (gce-demo-provision.sh, gce-demo-cluster.sh,
# gce-start-hub.sh, ...) inherit them.
#
# Everything here is a shell default (`${VAR:-...}`) so any value can still be
# overridden from the environment or an env file (see env.sample).

# --- Primary identity ---
# HUB_NAME drives stock resource naming (scion-${HUB_NAME}-*). Using "hub"
# yields scion-hub, scion-hub-lb-ip, etc.
export HUB_NAME="${HUB_NAME:-hub}"

# Project comes from the active gcloud config unless overridden.
export PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"

# --- Hub admin(s) ---
# The hub owner/admin. Written into settings.yaml as
# server.hub.admin_emails so this account is reconciled to the "admin" role on
# OAuth login and can see the admin console (telemetry, maintenance, users).
export HUB_ADMIN_EMAILS="${HUB_ADMIN_EMAILS:-admin@example.com}"

# --- Region / zone ---
export REGION="${REGION:-us-central1}"
export ZONE="${ZONE:-us-central1-a}"

# --- Domain & DNS ---
# The hub is served at a single fully-qualified hostname. The LB's Google-managed
# certificate and Caddy's Let's Encrypt certificate both cover this domain;
# CERT_DOMAIN == HUB_DOMAIN here.
export HUB_DOMAIN="${HUB_DOMAIN:-scion.hub.example.com}"
export CERT_DOMAIN="${CERT_DOMAIN:-${HUB_DOMAIN}}"
# Cloud DNS managed zone that already hosts ${HUB_DOMAIN}.
export DNS_ZONE_NAME="${DNS_ZONE_NAME:-scion-hub-example-com}"

# --- Custom VPC / private VM / Cloud NAT ---
export NETWORK="${NETWORK:-scion-network}"
export SUBNET="${SUBNET:-scion-subnet}"
export SUBNET_RANGE="${SUBNET_RANGE:-10.0.0.0/20}"
export VM_EXTERNAL_IP="${VM_EXTERNAL_IP:-false}"
export ROUTER_NAME="${ROUTER_NAME:-scion-router}"
export NAT_NAME="${NAT_NAME:-scion-nat}"
# Some organization policies enforce constraints/compute.requireShieldedVm — the
# VM must be a Shielded VM (Secure Boot + vTPM + integrity monitoring) or
# `instances create` is rejected.
export SHIELDED_VM="${SHIELDED_VM:-true}"
# Private VM => SSH only via IAP tunnelling.
export SSH_TUNNEL_FLAG="${SSH_TUNNEL_FLAG:---tunnel-through-iap}"

# --- Global external HTTPS load balancer (re-encrypts to Caddy on the VM) ---
export ENABLE_LB="${ENABLE_LB:-true}"
export HUB_PORT="${HUB_PORT:-8080}"
# Client TLS terminates at the LB (managed cert); the LB re-encrypts to Caddy on
# the VM over HTTPS :443, and Caddy reverse-proxies to the hub on HUB_PORT. The
# LB health check hits the hub's plain-HTTP port directly (no Caddy dependency).
export LB_BACKEND_PROTOCOL="${LB_BACKEND_PROTOCOL:-HTTPS}"
export LB_BACKEND_PORT="${LB_BACKEND_PORT:-443}"
export LB_HC_PORT="${LB_HC_PORT:-${HUB_PORT}}"
export LB_IP_NAME="${LB_IP_NAME:-scion-${HUB_NAME}-lb-ip}"
export LB_IG_NAME="${LB_IG_NAME:-scion-${HUB_NAME}-ig}"
export LB_HC_NAME="${LB_HC_NAME:-scion-${HUB_NAME}-lb-http-hc}"
export LB_BACKEND_NAME="${LB_BACKEND_NAME:-scion-${HUB_NAME}-backend}"
export LB_URLMAP_NAME="${LB_URLMAP_NAME:-scion-${HUB_NAME}-urlmap}"
export LB_CERT_NAME="${LB_CERT_NAME:-scion-${HUB_NAME}-sslcert}"
export LB_PROXY_NAME="${LB_PROXY_NAME:-scion-${HUB_NAME}-target-proxy}"
export LB_FORWARDING_RULE_NAME="${LB_FORWARDING_RULE_NAME:-scion-${HUB_NAME}-forwarding-rule}"

# --- Deploy behavior ---
# origin here is the read-only upstream GoogleCloudPlatform/scion, and the VM
# clones + pulls that upstream directly in gce-start-hub.sh's remote session, so
# the local "git push origin" step is both impossible (no write access) and moot.
# Skip it.
export SKIP_PUSH="${SKIP_PUSH:-true}"

# --- Telemetry service account ---
# Under an org policy enforcing constraints/iam.disableServiceAccountKeyCreation,
# downloading an SA key always fails. Default the telemetry SA step to keyless
# (create SA + roles, consume via ADC — the VM's attached SA) rather than relying
# on gce-demo-telemetry-sa.sh's org-policy auto-fallback, which would emit
# alarming "blocked by organization policy" warnings on every deploy.
export TELEMETRY_KEYLESS="${TELEMETRY_KEYLESS:-true}"

# --- Agent runtime: Docker on the hub VM (no GKE) ---
# ENABLE_GKE=false makes the hub use Docker as its runtime and skips all GKE
# cluster creation, container.admin IAM, and the container.googleapis.com API.
# The stock cloud-init already installs Docker and adds the scion user to the
# docker group, so agents run as containers on the VM.
export ENABLE_GKE="${ENABLE_GKE:-false}"
export CREATE_CLUSTER="${CREATE_CLUSTER:-false}"

# --- VM sizing ---
# e2-standard-4 (matches SIZE_CHOICE=1, "Small"). Setting MACHINE_TYPE directly
# means gce-demo-provision.sh never prompts.
export MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"
export SIZE_CHOICE="${SIZE_CHOICE:-1}"

# --- Hub image registry (non-secret; derived, no project literal committed) ---
# Artifact Registry path the hub pulls agent images from. Override via env/env
# file if your registry differs.
export SCION_IMAGE_REGISTRY="${SCION_IMAGE_REGISTRY:-${REGION}-docker.pkg.dev/${PROJECT_ID}/scion/scion}"

# Pull in all derived names (INSTANCE_NAME, SERVICE_ACCOUNT_NAME, HUB_ENV_FILE,
# ...) and shared helpers (wait_for_cloud_init) from the stock config.
_OVERLAY_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hub-config.sh
source "${_OVERLAY_CONFIG_DIR}/../hub-config.sh"
