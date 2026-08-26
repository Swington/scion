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

# scripts/starter-hub/private-lb/network.sh
#
# Create (or delete) the custom VPC networking the private-VM topology
# needs: a custom-mode VPC, a subnet with Private Google Access, a Cloud Router,
# and a Cloud NAT so the private VM (no external IP) can reach the internet for
# git/apt/image pulls.
#
# Usage:
#   network.sh            # create (idempotent)
#   network.sh delete     # delete NAT, router, subnet, VPC

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

if [[ -z "${PROJECT_ID}" ]]; then
    echo "Error: PROJECT_ID is not set and could not be determined from gcloud config."
    exit 1
fi

function delete_resources() {
    echo "=== Deleting private-LB network resources ==="

    if gcloud compute routers nats describe "${NAT_NAME}" --router "${ROUTER_NAME}" --region "${REGION}" --project "${PROJECT_ID}" &>/dev/null; then
        echo "Deleting Cloud NAT ${NAT_NAME}..."
        gcloud compute routers nats delete "${NAT_NAME}" --router "${ROUTER_NAME}" --region "${REGION}" --project "${PROJECT_ID}" --quiet
    else
        echo "Cloud NAT ${NAT_NAME} not found."
    fi

    if gcloud compute routers describe "${ROUTER_NAME}" --region "${REGION}" --project "${PROJECT_ID}" &>/dev/null; then
        echo "Deleting Cloud Router ${ROUTER_NAME}..."
        gcloud compute routers delete "${ROUTER_NAME}" --region "${REGION}" --project "${PROJECT_ID}" --quiet
    else
        echo "Cloud Router ${ROUTER_NAME} not found."
    fi

    if gcloud compute networks subnets describe "${SUBNET}" --region "${REGION}" --project "${PROJECT_ID}" &>/dev/null; then
        echo "Deleting subnet ${SUBNET}..."
        gcloud compute networks subnets delete "${SUBNET}" --region "${REGION}" --project "${PROJECT_ID}" --quiet
    else
        echo "Subnet ${SUBNET} not found."
    fi

    if gcloud compute networks describe "${NETWORK}" --project "${PROJECT_ID}" &>/dev/null; then
        echo "Deleting VPC ${NETWORK}..."
        gcloud compute networks delete "${NETWORK}" --project "${PROJECT_ID}" --quiet
    else
        echo "VPC ${NETWORK} not found."
    fi

    echo "=== Network deletion complete ==="
}

if [[ "${1:-}" == "delete" ]]; then
    delete_resources
    exit 0
fi

if [[ "${NETWORK}" == "default" ]]; then
    echo "NETWORK is 'default'; nothing to create (stock behavior uses the default VPC)."
    exit 0
fi

echo "=== Provisioning private-LB network ==="
echo "Project: ${PROJECT_ID}"
echo "VPC:     ${NETWORK}"
echo "Subnet:  ${SUBNET} (${SUBNET_RANGE}) in ${REGION}"

echo "Enabling compute API..."
gcloud services enable compute.googleapis.com --project "${PROJECT_ID}"

# Custom-mode VPC (no auto subnets).
if ! gcloud compute networks describe "${NETWORK}" --project "${PROJECT_ID}" &>/dev/null; then
    echo "Creating VPC ${NETWORK}..."
    gcloud compute networks create "${NETWORK}" \
        --project "${PROJECT_ID}" \
        --subnet-mode=custom
else
    echo "VPC ${NETWORK} already exists."
fi

# Subnet with Private Google Access (so the private VM can reach Google APIs).
if ! gcloud compute networks subnets describe "${SUBNET}" --region "${REGION}" --project "${PROJECT_ID}" &>/dev/null; then
    echo "Creating subnet ${SUBNET}..."
    gcloud compute networks subnets create "${SUBNET}" \
        --project "${PROJECT_ID}" \
        --network "${NETWORK}" \
        --region "${REGION}" \
        --range "${SUBNET_RANGE}" \
        --enable-private-ip-google-access
else
    echo "Subnet ${SUBNET} already exists."
fi

# Cloud Router + Cloud NAT for egress from the private VM.
if ! gcloud compute routers describe "${ROUTER_NAME}" --region "${REGION}" --project "${PROJECT_ID}" &>/dev/null; then
    echo "Creating Cloud Router ${ROUTER_NAME}..."
    gcloud compute routers create "${ROUTER_NAME}" \
        --project "${PROJECT_ID}" \
        --network "${NETWORK}" \
        --region "${REGION}"
else
    echo "Cloud Router ${ROUTER_NAME} already exists."
fi

if ! gcloud compute routers nats describe "${NAT_NAME}" --router "${ROUTER_NAME}" --region "${REGION}" --project "${PROJECT_ID}" &>/dev/null; then
    echo "Creating Cloud NAT ${NAT_NAME}..."
    gcloud compute routers nats create "${NAT_NAME}" \
        --project "${PROJECT_ID}" \
        --router "${ROUTER_NAME}" \
        --region "${REGION}" \
        --auto-allocate-nat-external-ips \
        --nat-all-subnet-ip-ranges
else
    echo "Cloud NAT ${NAT_NAME} already exists."
fi

echo ""
echo "=== Network ready ==="
echo "To delete, run: $0 delete"
