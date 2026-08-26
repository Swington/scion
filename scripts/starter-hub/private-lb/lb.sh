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

# scripts/starter-hub/private-lb/lb.sh
#
# Create (or delete) the global external HTTPS load balancer that fronts the
# private hub VM. The LB terminates client TLS with a Google-managed certificate
# and RE-ENCRYPTS to Caddy on the VM over ${LB_BACKEND_PROTOCOL}:${LB_BACKEND_PORT}
# ("double TLS"); Caddy serves its Let's Encrypt cert and reverse-proxies to the
# hub. The LB health check targets the hub's plain-HTTP port (${LB_HC_PORT})
# directly. It also manages the DNS A record pointing ${HUB_DOMAIN} at the LB's
# static IP.
#
# Component chain (creation order):
#   global static IP
#     -> unmanaged instance group (named port <proto>:${LB_BACKEND_PORT}) + VM member
#     -> HTTP health check (/healthz on ${LB_HC_PORT}, direct to the hub)
#     -> backend service (EXTERNAL, ${LB_BACKEND_PROTOCOL}) + backend
#     -> URL map (default -> backend)
#     -> managed SSL cert (${HUB_DOMAIN})
#     -> target HTTPS proxy
#     -> global forwarding rule (:443 -> proxy, on the static IP)
#     -> DNS A record (${HUB_DOMAIN} -> static IP)
#
# Usage:
#   lb.sh                 # create (idempotent), then wait for cert + e2e check
#   lb.sh delete          # delete LB chain; PRESERVE static IP + DNS record
#   lb.sh delete --release-ip   # also release the static IP and remove DNS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

if [[ -z "${PROJECT_ID}" ]]; then
    echo "Error: PROJECT_ID is not set and could not be determined from gcloud config."
    exit 1
fi

GP=(--global --project "${PROJECT_ID}")

# Instance-group named port / backend port-name, derived from the backend
# protocol (e.g. HTTPS -> "https", HTTP -> "http").
PORT_NAME="$(echo "${LB_BACKEND_PROTOCOL}" | tr '[:upper:]' '[:lower:]')"

# Look up the LB's reserved static IP address (empty if not reserved yet).
function lb_ip_address() {
    gcloud compute addresses describe "${LB_IP_NAME}" --global --project "${PROJECT_ID}" \
        --format='value(address)' 2>/dev/null || true
}

function delete_resources() {
    local release_ip="${1:-false}"
    echo "=== Deleting private-LB load balancer ==="

    if gcloud compute forwarding-rules describe "${LB_FORWARDING_RULE_NAME}" "${GP[@]}" &>/dev/null; then
        echo "Deleting forwarding rule ${LB_FORWARDING_RULE_NAME}..."
        gcloud compute forwarding-rules delete "${LB_FORWARDING_RULE_NAME}" "${GP[@]}" --quiet
    else
        echo "Forwarding rule ${LB_FORWARDING_RULE_NAME} not found."
    fi

    if gcloud compute target-https-proxies describe "${LB_PROXY_NAME}" "${GP[@]}" &>/dev/null; then
        echo "Deleting target HTTPS proxy ${LB_PROXY_NAME}..."
        gcloud compute target-https-proxies delete "${LB_PROXY_NAME}" "${GP[@]}" --quiet
    else
        echo "Target HTTPS proxy ${LB_PROXY_NAME} not found."
    fi

    if gcloud compute ssl-certificates describe "${LB_CERT_NAME}" "${GP[@]}" &>/dev/null; then
        echo "Deleting managed SSL certificate ${LB_CERT_NAME}..."
        gcloud compute ssl-certificates delete "${LB_CERT_NAME}" "${GP[@]}" --quiet
    else
        echo "SSL certificate ${LB_CERT_NAME} not found."
    fi

    if gcloud compute url-maps describe "${LB_URLMAP_NAME}" "${GP[@]}" &>/dev/null; then
        echo "Deleting URL map ${LB_URLMAP_NAME}..."
        gcloud compute url-maps delete "${LB_URLMAP_NAME}" "${GP[@]}" --quiet
    else
        echo "URL map ${LB_URLMAP_NAME} not found."
    fi

    if gcloud compute backend-services describe "${LB_BACKEND_NAME}" "${GP[@]}" &>/dev/null; then
        echo "Deleting backend service ${LB_BACKEND_NAME}..."
        gcloud compute backend-services delete "${LB_BACKEND_NAME}" "${GP[@]}" --quiet
    else
        echo "Backend service ${LB_BACKEND_NAME} not found."
    fi

    if gcloud compute health-checks describe "${LB_HC_NAME}" "${GP[@]}" &>/dev/null; then
        echo "Deleting health check ${LB_HC_NAME}..."
        gcloud compute health-checks delete "${LB_HC_NAME}" "${GP[@]}" --quiet
    else
        echo "Health check ${LB_HC_NAME} not found."
    fi

    if gcloud compute instance-groups unmanaged describe "${LB_IG_NAME}" --zone "${ZONE}" --project "${PROJECT_ID}" &>/dev/null; then
        echo "Deleting instance group ${LB_IG_NAME}..."
        gcloud compute instance-groups unmanaged delete "${LB_IG_NAME}" --zone "${ZONE}" --project "${PROJECT_ID}" --quiet
    else
        echo "Instance group ${LB_IG_NAME} not found."
    fi

    if [[ "${release_ip}" == "true" ]]; then
        local ip
        ip="$(lb_ip_address)"
        if [[ -n "${ip}" ]]; then
            echo "Removing DNS A record ${HUB_DOMAIN} -> ${ip}..."
            delete_dns_record "${ip}"
        fi
        if gcloud compute addresses describe "${LB_IP_NAME}" --global --project "${PROJECT_ID}" &>/dev/null; then
            echo "Releasing static IP ${LB_IP_NAME}..."
            gcloud compute addresses delete "${LB_IP_NAME}" --global --project "${PROJECT_ID}" --quiet
        fi
    else
        echo "Preserving static IP ${LB_IP_NAME} and DNS record (re-use on next deploy)."
        echo "  (pass 'delete --release-ip' to also release the IP and DNS record.)"
    fi

    echo "=== Load balancer deletion complete ==="
}

# Upsert the ${HUB_DOMAIN} A record to point at $1 in the managed zone.
function upsert_dns_record() {
    local ip="$1"
    local existing
    existing="$(gcloud dns record-sets list --zone "${DNS_ZONE_NAME}" --project "${PROJECT_ID}" \
        --name "${HUB_DOMAIN}." --type A --format='value(rrdatas[0])' 2>/dev/null || true)"
    if [[ "${existing}" == "${ip}" ]]; then
        echo "  -> DNS A record ${HUB_DOMAIN} already points at ${ip}."
        return 0
    fi
    if [[ -n "${existing}" ]]; then
        echo "  -> Updating DNS A record ${HUB_DOMAIN}: ${existing} -> ${ip}"
        gcloud dns record-sets update "${HUB_DOMAIN}." --zone "${DNS_ZONE_NAME}" --project "${PROJECT_ID}" \
            --type A --ttl 300 --rrdatas "${ip}"
    else
        echo "  -> Creating DNS A record ${HUB_DOMAIN} -> ${ip}"
        gcloud dns record-sets create "${HUB_DOMAIN}." --zone "${DNS_ZONE_NAME}" --project "${PROJECT_ID}" \
            --type A --ttl 300 --rrdatas "${ip}"
    fi
}

# Remove the ${HUB_DOMAIN} A record if it points at $1.
function delete_dns_record() {
    local ip="$1"
    local existing
    existing="$(gcloud dns record-sets list --zone "${DNS_ZONE_NAME}" --project "${PROJECT_ID}" \
        --name "${HUB_DOMAIN}." --type A --format='value(rrdatas[0])' 2>/dev/null || true)"
    if [[ -n "${existing}" ]]; then
        gcloud dns record-sets delete "${HUB_DOMAIN}." --zone "${DNS_ZONE_NAME}" --project "${PROJECT_ID}" \
            --type A --quiet
    fi
}

if [[ "${1:-}" == "delete" ]]; then
    if [[ "${2:-}" == "--release-ip" ]]; then
        delete_resources true
    else
        delete_resources false
    fi
    exit 0
fi

echo "=== Provisioning private-LB load balancer ==="
echo "Project: ${PROJECT_ID}"
echo "Domain:  ${HUB_DOMAIN}"
echo "Backend: ${INSTANCE_NAME} (${LB_BACKEND_PROTOCOL} :${LB_BACKEND_PORT}, health check :${LB_HC_PORT})"

# 1. Global static IP (reused across rebuilds so the URL never changes).
if ! gcloud compute addresses describe "${LB_IP_NAME}" --global --project "${PROJECT_ID}" &>/dev/null; then
    echo "Reserving global static IP ${LB_IP_NAME}..."
    gcloud compute addresses create "${LB_IP_NAME}" --global --project "${PROJECT_ID}"
else
    echo "Static IP ${LB_IP_NAME} already reserved."
fi
LB_IP="$(lb_ip_address)"
echo "  -> Static IP: ${LB_IP}"

# 2. Unmanaged instance group with the hub port named, plus the VM as a member.
if ! gcloud compute instance-groups unmanaged describe "${LB_IG_NAME}" --zone "${ZONE}" --project "${PROJECT_ID}" &>/dev/null; then
    echo "Creating instance group ${LB_IG_NAME}..."
    gcloud compute instance-groups unmanaged create "${LB_IG_NAME}" --zone "${ZONE}" --project "${PROJECT_ID}"
else
    echo "Instance group ${LB_IG_NAME} already exists."
fi
echo "Setting named port ${PORT_NAME}:${LB_BACKEND_PORT}..."
gcloud compute instance-groups set-named-ports "${LB_IG_NAME}" --zone "${ZONE}" --project "${PROJECT_ID}" \
    --named-ports "${PORT_NAME}:${LB_BACKEND_PORT}"
if ! gcloud compute instance-groups unmanaged list-instances "${LB_IG_NAME}" --zone "${ZONE}" --project "${PROJECT_ID}" \
        --format='value(instance)' 2>/dev/null | grep -q "/${INSTANCE_NAME}$"; then
    echo "Adding ${INSTANCE_NAME} to instance group..."
    gcloud compute instance-groups unmanaged add-instances "${LB_IG_NAME}" --zone "${ZONE}" --project "${PROJECT_ID}" \
        --instances "${INSTANCE_NAME}"
else
    echo "Instance ${INSTANCE_NAME} already in group."
fi

# 3. Health check (HTTP /healthz direct to the hub's plain-HTTP port, so it does
#    not depend on Caddy's host-based routing / SNI).
if ! gcloud compute health-checks describe "${LB_HC_NAME}" "${GP[@]}" &>/dev/null; then
    echo "Creating health check ${LB_HC_NAME}..."
    gcloud compute health-checks create http "${LB_HC_NAME}" "${GP[@]}" \
        --port "${LB_HC_PORT}" \
        --request-path "/healthz"
else
    echo "Health check ${LB_HC_NAME} already exists."
fi

# 4. Backend service (external; re-encrypts to Caddy via the named port) + backend.
if ! gcloud compute backend-services describe "${LB_BACKEND_NAME}" "${GP[@]}" &>/dev/null; then
    echo "Creating backend service ${LB_BACKEND_NAME} (${LB_BACKEND_PROTOCOL})..."
    gcloud compute backend-services create "${LB_BACKEND_NAME}" "${GP[@]}" \
        --load-balancing-scheme EXTERNAL \
        --protocol "${LB_BACKEND_PROTOCOL}" \
        --port-name "${PORT_NAME}" \
        --health-checks "${LB_HC_NAME}"
else
    echo "Backend service ${LB_BACKEND_NAME} already exists."
fi
if ! gcloud compute backend-services describe "${LB_BACKEND_NAME}" "${GP[@]}" \
        --format='value(backends[].group)' 2>/dev/null | grep -q "/${LB_IG_NAME}$"; then
    echo "Adding instance group to backend service..."
    gcloud compute backend-services add-backend "${LB_BACKEND_NAME}" "${GP[@]}" \
        --instance-group "${LB_IG_NAME}" \
        --instance-group-zone "${ZONE}" \
        --balancing-mode UTILIZATION \
        --max-utilization 0.8
else
    echo "Backend already attached to backend service."
fi

# 5. URL map (all paths -> backend).
if ! gcloud compute url-maps describe "${LB_URLMAP_NAME}" "${GP[@]}" &>/dev/null; then
    echo "Creating URL map ${LB_URLMAP_NAME}..."
    gcloud compute url-maps create "${LB_URLMAP_NAME}" "${GP[@]}" \
        --default-service "${LB_BACKEND_NAME}"
else
    echo "URL map ${LB_URLMAP_NAME} already exists."
fi

# 6. Google-managed SSL certificate for the hub domain.
if ! gcloud compute ssl-certificates describe "${LB_CERT_NAME}" "${GP[@]}" &>/dev/null; then
    echo "Creating managed SSL certificate ${LB_CERT_NAME} for ${HUB_DOMAIN}..."
    gcloud compute ssl-certificates create "${LB_CERT_NAME}" "${GP[@]}" \
        --domains "${HUB_DOMAIN}"
else
    echo "SSL certificate ${LB_CERT_NAME} already exists."
fi

# 7. Target HTTPS proxy binding the URL map + cert.
if ! gcloud compute target-https-proxies describe "${LB_PROXY_NAME}" "${GP[@]}" &>/dev/null; then
    echo "Creating target HTTPS proxy ${LB_PROXY_NAME}..."
    gcloud compute target-https-proxies create "${LB_PROXY_NAME}" "${GP[@]}" \
        --url-map "${LB_URLMAP_NAME}" \
        --ssl-certificates "${LB_CERT_NAME}"
else
    echo "Target HTTPS proxy ${LB_PROXY_NAME} already exists."
fi

# 8. Global forwarding rule (:443 on the static IP -> proxy).
if ! gcloud compute forwarding-rules describe "${LB_FORWARDING_RULE_NAME}" "${GP[@]}" &>/dev/null; then
    echo "Creating global forwarding rule ${LB_FORWARDING_RULE_NAME}..."
    gcloud compute forwarding-rules create "${LB_FORWARDING_RULE_NAME}" "${GP[@]}" \
        --load-balancing-scheme EXTERNAL \
        --address "${LB_IP_NAME}" \
        --target-https-proxy "${LB_PROXY_NAME}" \
        --ports 443
else
    echo "Forwarding rule ${LB_FORWARDING_RULE_NAME} already exists."
fi

# 9. DNS: point the hub domain at the LB static IP (required before the managed
#    cert can validate).
echo "Ensuring DNS A record..."
upsert_dns_record "${LB_IP}"

# 10. Wait for the managed certificate to become ACTIVE (domain validation can
#     take 15-30+ minutes on first provision).
echo ""
echo "=== Waiting for managed certificate to become ACTIVE ==="
echo "(First-time issuance can take 15-30 minutes; this polls up to 40.)"
CERT_ACTIVE=false
for (( i = 1; i <= 80; i++ )); do
    STATUS="$(gcloud compute ssl-certificates describe "${LB_CERT_NAME}" "${GP[@]}" \
        --format='value(managed.status)' 2>/dev/null || true)"
    DOMAIN_STATUS="$(gcloud compute ssl-certificates describe "${LB_CERT_NAME}" "${GP[@]}" \
        --format="value(managed.domainStatus.${HUB_DOMAIN})" 2>/dev/null || true)"
    echo "  -> [$i/80] cert=${STATUS:-unknown} domain=${DOMAIN_STATUS:-unknown}"
    if [[ "${STATUS}" == "ACTIVE" ]]; then
        CERT_ACTIVE=true
        break
    fi
    sleep 30
done

if [[ "${CERT_ACTIVE}" != "true" ]]; then
    echo "Warning: certificate not ACTIVE yet. It may still finish provisioning."
    echo "Check later with:"
    echo "  gcloud compute ssl-certificates describe ${LB_CERT_NAME} --global --format='value(managed.status)'"
    echo "Static IP: ${LB_IP}  Domain: ${HUB_DOMAIN}"
    exit 0
fi

# 11. End-to-end check.
echo ""
echo "=== End-to-end health check: https://${HUB_DOMAIN}/healthz ==="
for (( i = 1; i <= 12; i++ )); do
    if curl -s "https://${HUB_DOMAIN}/healthz" | grep -q '"status":"healthy"'; then
        echo "  -> Hub is healthy behind the load balancer!"
        curl -s "https://${HUB_DOMAIN}/healthz"
        echo ""
        echo ""
        echo "=== Load balancer ready: https://${HUB_DOMAIN} (${LB_IP}) ==="
        exit 0
    fi
    echo "  -> Waiting for end-to-end health... ($i/12)"
    sleep 10
done

echo "Warning: end-to-end health check did not pass yet (cert is ACTIVE)."
echo "The hub service may still be starting; retry: curl https://${HUB_DOMAIN}/healthz"
