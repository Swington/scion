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

# scripts/starter-hub/private-lb/deploy.sh
#
# One-stop deploy/teardown for the private-LB starter-hub topology:
#   custom VPC + private VM (Cloud NAT egress) + global external HTTPS LB,
#   agents running as Docker containers on the hub VM (no GKE).
#
# Run from the repository root (the stock scripts use ./scripts/... paths).
#
# Usage:
#   deploy.sh                     # full deploy
#   deploy.sh delete              # tear down; PRESERVE static IP, DNS,
#                                 #   GCS bucket, and Secret Manager secrets
#   deploy.sh delete --release-ip # also release the static IP + DNS record
#
# Env toggles:
#   SKIP_PREFLIGHT=true   # skip the stock preflight validation gate

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

# Stock scripts reference ./scripts/starter-hub/... relative to the repo root.
cd "${REPO_ROOT}"

STOCK="scripts/starter-hub"
OVERLAY="scripts/starter-hub/private-lb"

if [[ "${1:-}" == "delete" ]]; then
    RELEASE_FLAG="${2:-}"
    echo "=== Private-LB teardown ==="
    echo ""
    echo "--- Deleting load balancer ---"
    if [[ "${RELEASE_FLAG}" == "--release-ip" ]]; then
        "${OVERLAY}/lb.sh" delete --release-ip
    else
        "${OVERLAY}/lb.sh" delete
    fi

    echo ""
    echo "--- Deleting VM, service account, and firewall rules ---"
    "${STOCK}/gce-demo-provision.sh" delete

    echo ""
    echo "--- Deleting custom VPC networking ---"
    "${OVERLAY}/network.sh" delete

    echo ""
    echo "=== Teardown complete ==="
    if [[ "${RELEASE_FLAG}" == "--release-ip" ]]; then
        echo "Static IP and DNS record were released."
    else
        echo "Preserved: static IP (${LB_IP_NAME}), DNS record (${HUB_DOMAIN})."
    fi
    echo "Preserved: GCS bucket and Secret Manager OAuth secrets (never touched by teardown)."
    exit 0
fi

echo "=== Private-LB full deploy: ${HUB_DOMAIN} ==="
echo "Project: ${PROJECT_ID}"
echo "Runtime: Docker on the hub VM (ENABLE_GKE=${ENABLE_GKE})"

# Step 1: Custom VPC + subnet + Cloud Router + Cloud NAT.
echo ""
echo "--- Step 1: Network ---"
"${OVERLAY}/network.sh"

# Step 2: APIs, service account + roles, firewall (GCLB + IAP-SSH), private VM.
echo ""
echo "--- Step 2: Provision VM ---"
"${STOCK}/gce-demo-provision.sh"

# Step 3: Telemetry service account.
echo ""
echo "--- Step 3: Telemetry service account ---"
"${STOCK}/gce-demo-telemetry-sa.sh"

# Step 4: Clone the repo on the VM (over IAP tunnel).
echo ""
echo "--- Step 4: Setup repository ---"
"${STOCK}/gce-demo-setup-repo.sh"

# Step 5: Generate the hub env file from Secret Manager.
echo ""
echo "--- Step 5: Hub environment (Secret Manager) ---"
"${OVERLAY}/hubenv.sh"

# Step 6 (optional): stock preflight as a validation gate now that the env file
# exists. Some warnings (Caddy/Let's Encrypt, DNS-zone-created-by-certs) do not
# apply to the LB path and are safe to ignore.
if [[ "${SKIP_PREFLIGHT:-false}" != "true" ]]; then
    echo ""
    echo "--- Step 6: Preflight validation ---"
    "${STOCK}/gce-demo-preflight.sh" || {
        echo "Preflight reported errors. Fix them or re-run with SKIP_PREFLIGHT=true." >&2
        exit 1
    }
fi

# Step 7: Obtain the Let's Encrypt certificate on the VM (certbot DNS-01). Caddy
# needs this cert on disk before it starts. In LB mode gce-certs.sh skips
# A-record management (the LB owns the A record) and uses the IAP SSH tunnel.
echo ""
echo "--- Step 7: TLS certificate on the VM ---"
"${STOCK}/gce-certs.sh"

# Step 8: Build + start the hub on the VM. Caddy terminates the LE cert on :443
# and reverse-proxies to the hub on :${HUB_PORT}.
echo ""
echo "--- Step 8: Build and start hub ---"
"${STOCK}/gce-start-hub.sh" --full

# Step 9: Global external HTTPS load balancer + managed cert + DNS. The LB
# re-encrypts to Caddy on the VM ("double TLS").
echo ""
echo "--- Step 9: Load balancer ---"
"${OVERLAY}/lb.sh"

echo ""
echo "=== Private-LB deploy complete ==="
echo "Hub URL: https://${HUB_DOMAIN}"
