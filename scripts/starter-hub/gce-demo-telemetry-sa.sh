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

# scripts/starter-hub/gce-demo-telemetry-sa.sh - Create GCP service account for agent telemetry export
#
# Creates a dedicated, least-privilege service account for writing telemetry
# data (traces, logs, metrics) to Google Cloud Observability. By default a JSON
# key is downloaded locally for injection into agent containers via the Hub
# secrets system.
#
# KEYLESS MODE: some organizations enforce
# constraints/iam.disableServiceAccountKeyCreation, which forbids downloading SA
# keys. Set TELEMETRY_KEYLESS=true to create the SA and
# grant roles WITHOUT a key; the SA is then consumed via Application Default
# Credentials (attach it to the VM / bind via Workload Identity) instead of a
# key file. The script ALSO auto-detects this policy: if key creation is denied
# by it, the script degrades to keyless behavior instead of failing.
#
# Usage:
#   ./scripts/starter-hub/gce-demo-telemetry-sa.sh          # Create SA, grant roles, download key
#   TELEMETRY_KEYLESS=true ./scripts/starter-hub/gce-demo-telemetry-sa.sh   # SA + roles only (no key)
#   ./scripts/starter-hub/gce-demo-telemetry-sa.sh delete    # Remove SA and local key file
#
# The key file is written to .scratch/telemetry-gcp-credentials.json
# (git-ignored). It should be uploaded to the Hub as a file-type secret named
# "scion-telemetry-gcp-credentials" with target "~/.scion/telemetry-gcp-credentials.json".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hub-config.sh
source "${SCRIPT_DIR}/hub-config.sh"

SA_NAME="scion-telemetry-writer"
KEY_DIR=".scratch"
KEY_FILE="${KEY_DIR}/telemetry-gcp-credentials.json"

# Keyless mode: create the SA and grant roles but do NOT download a JSON key.
# Required under org policies enforcing constraints/iam.disableServiceAccountKeyCreation.
TELEMETRY_KEYLESS="${TELEMETRY_KEYLESS:-false}"

if [[ -z "$PROJECT_ID" ]]; then
    echo "Error: PROJECT_ID is not set and could not be determined from gcloud config."
    exit 1
fi

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# --- IAM roles: write-only telemetry access (see .design/hosted/metrics-design-gcp-auth.md §3.2) ---
ROLES=(
    "roles/cloudtrace.agent"
    "roles/logging.logWriter"
    "roles/monitoring.metricWriter"
)

function delete_resources() {
    echo "=== Deleting Telemetry Service Account ==="

    # Remove IAM bindings
    for role in "${ROLES[@]}"; do
        if gcloud projects get-iam-policy "${PROJECT_ID}" \
            --flatten="bindings[].members" \
            --filter="bindings.members:serviceAccount:${SA_EMAIL} AND bindings.role:${role}" \
            --format="value(bindings.role)" 2>/dev/null | grep -q "${role}"; then
            echo "Removing ${role}..."
            gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
                --member "serviceAccount:${SA_EMAIL}" \
                --role "${role}" > /dev/null
        fi
    done

    # Delete service account
    if gcloud iam service-accounts describe "${SA_EMAIL}" &>/dev/null; then
        echo "Deleting service account ${SA_EMAIL}..."
        gcloud iam service-accounts delete "${SA_EMAIL}" --quiet
    else
        echo "Service account ${SA_EMAIL} not found."
    fi

    # Remove local key file
    if [[ -f "${KEY_FILE}" ]]; then
        echo "Removing local key file ${KEY_FILE}..."
        rm -f "${KEY_FILE}"
    fi

    echo "=== Deletion Complete ==="
}

if [[ "${1:-}" == "delete" ]]; then
    delete_resources
    exit 0
fi

echo "=== Telemetry Service Account Setup ==="
echo "Project:         ${PROJECT_ID}"
echo "Service Account: ${SA_NAME}"
echo "Key File:        ${KEY_FILE}"
echo ""

# Enable required APIs
echo "Enabling required Google Cloud APIs..."
gcloud services enable \
    cloudtrace.googleapis.com \
    logging.googleapis.com \
    monitoring.googleapis.com \
    --project "${PROJECT_ID}"

# Create service account if it doesn't exist
if ! gcloud iam service-accounts describe "${SA_EMAIL}" &>/dev/null; then
    echo "Creating service account ${SA_NAME}..."
    gcloud iam service-accounts create "${SA_NAME}" \
        --project="${PROJECT_ID}" \
        --display-name "Scion Telemetry Writer" \
        --description "Least-privilege SA for agent telemetry export (traces, logs, metrics)"

    echo "Waiting for service account to propagate..."
    sleep 5
else
    echo "Service account ${SA_NAME} already exists."
fi

# Grant IAM roles
echo "Granting IAM roles..."
for role in "${ROLES[@]}"; do
    echo "  -> ${role}"
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member "serviceAccount:${SA_EMAIL}" \
        --role "${role}" > /dev/null
done

# Print how to consume the SA without a downloaded key (Application Default
# Credentials via an attached VM SA or Workload Identity).
print_keyless_guidance() {
    cat <<GUIDANCE

=== Keyless mode (no JSON key) ===
No service-account key was downloaded. Use Application Default Credentials (ADC)
to consume ${SA_EMAIL} instead of a key file:
  - GCE/VM: run the agent workload on a VM whose attached service account is
    ${SA_EMAIL} (or grant the telemetry roles above to the VM's runtime SA).
  - GKE:    bind ${SA_EMAIL} to the workload's KSA via Workload Identity.
Then set SCION_GCP_PROJECT_ID=${PROJECT_ID} so the exporter resolves the project
(ADC alone does not supply the project id).
GUIDANCE
}

# Create and download key (unless keyless, already present, or forbidden by policy)
mkdir -p "${KEY_DIR}"

if [[ "${TELEMETRY_KEYLESS}" == "true" ]]; then
    echo ""
    echo "TELEMETRY_KEYLESS=true — skipping key creation (service account + roles only)."
    print_keyless_guidance
elif [[ -f "${KEY_FILE}" ]]; then
    echo ""
    echo "Key file ${KEY_FILE} already exists."
    echo "To regenerate, delete it first and re-run this script."
else
    echo ""
    echo "Creating and downloading service account key..."
    KEY_ERR="$(mktemp)"
    if gcloud iam service-accounts keys create "${KEY_FILE}" \
        --iam-account "${SA_EMAIL}" 2>"${KEY_ERR}"; then
        chmod 600 "${KEY_FILE}"
        echo "Key saved to ${KEY_FILE} (mode 0600)"
        rm -f "${KEY_ERR}"
    elif grep -qiE 'disableServiceAccountKeyCreation|key creation is not allowed' "${KEY_ERR}"; then
        # Org policy forbids SA keys — degrade gracefully to keyless instead of failing.
        echo "  -> Service-account key creation is blocked by an organization policy" >&2
        echo "     (constraints/iam.disableServiceAccountKeyCreation). Falling back to keyless." >&2
        rm -f "${KEY_FILE}" "${KEY_ERR}"   # remove any partial/empty file
        print_keyless_guidance
    else
        # Any other failure is a real error — surface it and stop.
        echo "Error: failed to create service account key:" >&2
        cat "${KEY_ERR}" >&2
        rm -f "${KEY_ERR}"
        exit 1
    fi
fi

echo ""
echo "=== Success ==="
echo ""
if [[ -f "${KEY_FILE}" ]]; then
    echo "Next steps:"
    echo "  1. Upload the key to the Hub as a file-type secret:"
    echo ""
    echo "     scion hub secret set scion-telemetry-gcp-credentials \\"
    echo "       @${KEY_FILE} \\"
    echo "       --hub '<HUB_ENDPOINT_URL>' \\"
    echo "       --scope hub \\"
    echo "       --type file \\"
    echo "       --target '~/.scion/telemetry-gcp-credentials.json'"
    echo ""
    echo "  2. Ensure grove settings include 'provider: gcp' under telemetry.cloud"
else
    echo "Next steps (keyless):"
    echo "  1. Attach ${SA_EMAIL} to the agent runtime (VM attached SA or GKE"
    echo "     Workload Identity) so telemetry export uses ADC — see guidance above."
    echo "  2. Ensure grove settings include 'provider: gcp' under telemetry.cloud,"
    echo "     and set SCION_GCP_PROJECT_ID=${PROJECT_ID}."
fi
echo ""
echo "  To delete this SA, run: $0 delete"
