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

#
# Starter-hub config-generation test
# ===================================
# Hermetic unit tests for the hub configuration that the starter-hub scripts
# generate (settings.yaml + hub.env). No live GCP: `gcloud` and `openssl` are
# stubbed on PATH, so this runs anywhere with just bash.
#
# It pins the three admin-console prerequisites that a from-scratch rebuild must
# emit, each verified against the scion V1 settings schema (pkg/config/*):
#
#   1. server.hub.admin_emails         -> admins get the "admin" role on OAuth
#                                          login, so the admin console is visible.
#   2. telemetry.cloud.gcp_project_id  -> the hub can initialize the metrics
#                                          dashboard (else 503 metrics_unavailable).
#   3. SCION_MAINTENANCE_REPO_PATH      -> "check for updates" has a repo to fetch
#                                          (else "No repository path configured").
#
# Usage:
#   ./scripts/starter-hub/starter-hub-config-test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_CONFIG_SH="${SCRIPT_DIR}/hub-config.sh"
OVERLAY_CONFIG_SH="${SCRIPT_DIR}/private-lb/config.sh"
OVERLAY_HUBENV_SH="${SCRIPT_DIR}/private-lb/hubenv.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1"; }
log_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# assert_contains <description> <haystack> <needle>
assert_contains() {
    local description="$1" haystack="$2" needle="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        log_success "$description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "$description"
        log_error "  expected to contain: $needle"
        log_error "  actual output:"
        printf '%s\n' "$haystack" | sed 's/^/    /'
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# assert_not_contains <description> <haystack> <needle>
assert_not_contains() {
    local description="$1" haystack="$2" needle="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        log_error "$description"
        log_error "  expected NOT to contain: $needle"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        log_success "$description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
}

# assert_equals <description> <expected> <actual>
assert_equals() {
    local description="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        log_success "$description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "$description"
        log_error "  expected: '$expected'"
        log_error "  actual:   '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ============================================================================
# Hermetic stubs (gcloud, openssl) — keep the tests offline and deterministic.
# ============================================================================
STUB_BIN="$(mktemp -d)"
trap '[ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"; [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR"' EXIT

cat > "${STUB_BIN}/gcloud" <<'STUB'
#!/bin/bash
# Deterministic gcloud stub. `config get-value project` echoes $STUB_GCLOUD_PROJECT
# (empty unless set); secret access returns a fixed non-secret sentinel.
args="$*"
case "$args" in
    "config get-value project") echo "${STUB_GCLOUD_PROJECT:-}" ;;
    *"secrets versions access"*) echo "STUB-SECRET-VALUE" ;;
    *) echo "" ;;
esac
STUB
chmod +x "${STUB_BIN}/gcloud"

cat > "${STUB_BIN}/openssl" <<'STUB'
#!/bin/bash
if [[ "$1" == "rand" ]]; then
    echo "STUB-SESSION-SECRET"
else
    exec /usr/bin/openssl "$@"
fi
STUB
chmod +x "${STUB_BIN}/openssl"

export PATH="${STUB_BIN}:${PATH}"
WORK_DIR="$(mktemp -d)"

# run_emit — source hub-config.sh in a subshell (so its vars/functions don't leak
# between cases) and print the generated settings.yaml. Caller sets HUB_ADMIN_EMAILS
# / PROJECT_ID / ENABLE_GKE in the environment to drive the conditional blocks.
run_emit() {
    (
        source "$HUB_CONFIG_SH" >/dev/null 2>&1
        emit_settings_yaml
    )
}

# ============================================================================
log_section "settings.yaml: baseline (unchanged schema)"
# ============================================================================
BASE="$(PROJECT_ID='' HUB_ADMIN_EMAILS='' run_emit)"
assert_contains "schema_version pinned to \"1\"" "$BASE" 'schema_version: "1"'
assert_contains "default_runtime docker (ENABLE_GKE unset)" "$BASE" 'default_runtime: docker'
assert_contains "server.mode production" "$BASE" 'mode: production'
assert_contains "telemetry enabled" "$BASE" 'enabled: true'
assert_contains "telemetry filter redacts prompt" "$BASE" '- "prompt"'
assert_contains "telemetry filter hashes session_id" "$BASE" '- "session_id"'

# ============================================================================
log_section "settings.yaml: server.hub.admin_emails (admin-console visibility)"
# ============================================================================
ADMIN_ONE="$(PROJECT_ID='' HUB_ADMIN_EMAILS='admin@example.com' run_emit)"
assert_contains "emits server.hub block"        "$ADMIN_ONE" '  hub:'
assert_contains "emits admin_emails key"        "$ADMIN_ONE" '    admin_emails:'
assert_contains "emits the admin as a list item" "$ADMIN_ONE" '      - admin@example.com'

ADMIN_MANY="$(PROJECT_ID='' HUB_ADMIN_EMAILS='a@x.com, b@y.com ,c@z.com' run_emit)"
assert_contains "multi-admin: first entry"  "$ADMIN_MANY" '      - a@x.com'
assert_contains "multi-admin: trims spaces (middle)" "$ADMIN_MANY" '      - b@y.com'
assert_contains "multi-admin: last entry"   "$ADMIN_MANY" '      - c@z.com'

NO_ADMIN="$(PROJECT_ID='' HUB_ADMIN_EMAILS='' run_emit)"
assert_not_contains "no admin_emails when HUB_ADMIN_EMAILS empty" "$NO_ADMIN" 'admin_emails:'
assert_not_contains "no server.hub block when HUB_ADMIN_EMAILS empty" "$NO_ADMIN" '  hub:'

# ============================================================================
log_section "settings.yaml: telemetry.cloud.gcp_project_id (metrics dashboard)"
# ============================================================================
WITH_PROJ="$(PROJECT_ID='example-project' HUB_ADMIN_EMAILS='' run_emit)"
assert_contains "emits telemetry.cloud.gcp_project_id" "$WITH_PROJ" '    gcp_project_id: "example-project"'

NO_PROJ="$(PROJECT_ID='' HUB_ADMIN_EMAILS='' run_emit)"
assert_not_contains "no gcp_project_id when PROJECT_ID empty" "$NO_PROJ" 'gcp_project_id:'

# ============================================================================
log_section "settings.yaml: default_runtime tracks ENABLE_GKE"
# ============================================================================
GKE="$(PROJECT_ID='' HUB_ADMIN_EMAILS='' ENABLE_GKE='true' run_emit)"
assert_contains "default_runtime kubernetes when ENABLE_GKE=true" "$GKE" 'default_runtime: kubernetes'

# ============================================================================
log_section "private-lb/config.sh: HUB_ADMIN_EMAILS preset"
# ============================================================================
OVERLAY_ADMIN="$( STUB_GCLOUD_PROJECT='example-project' bash -c '
    source "'"$OVERLAY_CONFIG_SH"'" >/dev/null 2>&1
    printf "%s" "${HUB_ADMIN_EMAILS:-<unset>}"
' )"
assert_equals "private-lb overlay presets the overlay admin" \
    "admin@example.com" "$OVERLAY_ADMIN"

# Single-dash default distinguishes "defined but empty" (stock: "") from truly
# unset ("<unset>") — hub-config.sh must DEFINE the var so `set -u` callers are safe.
HUB_DEFAULT_ADMIN="$( STUB_GCLOUD_PROJECT='' bash -c '
    source "'"$HUB_CONFIG_SH"'" >/dev/null 2>&1
    printf "%s" "${HUB_ADMIN_EMAILS-<unset>}"
' )"
assert_equals "stock hub-config defines HUB_ADMIN_EMAILS as empty" "" "$HUB_DEFAULT_ADMIN"

# Under an org policy that forbids SA keys (constraints/iam.disableServiceAccountKeyCreation),
# the overlay should default the telemetry SA step to keyless — and EXPORT it so
# the child gce-demo-telemetry-sa.sh inherits it.
OVERLAY_KEYLESS="$( STUB_GCLOUD_PROJECT='example-project' bash -c '
    source "'"$OVERLAY_CONFIG_SH"'" >/dev/null 2>&1
    bash -c "printf %s \"\${TELEMETRY_KEYLESS:-<unset>}\""
' )"
assert_equals "private-lb overlay defaults telemetry SA to keyless (exported)" \
    "true" "$OVERLAY_KEYLESS"

# ============================================================================
log_section "hub.env: SCION_MAINTENANCE_REPO_PATH (check-for-updates)"
# ============================================================================
HUB_ENV_OUT="${WORK_DIR}/hub.env"
HUBENV_STDOUT="$(
    STUB_GCLOUD_PROJECT='example-project' \
    PROJECT_ID='example-project' \
    HUB_ENV_FILE="$HUB_ENV_OUT" \
    bash "$OVERLAY_HUBENV_SH" 2>&1
)"
HUB_ENV_CONTENT="$(cat "$HUB_ENV_OUT" 2>/dev/null || true)"
assert_contains "hub.env sets SCION_MAINTENANCE_REPO_PATH to REPO_DIR" \
    "$HUB_ENV_CONTENT" 'SCION_MAINTENANCE_REPO_PATH=/home/scion/scion'
assert_contains "hub.env still carries telemetry project" \
    "$HUB_ENV_CONTENT" 'SCION_GCP_PROJECT_ID=example-project'
assert_not_contains "generator never prints secret values to stdout" \
    "$HUBENV_STDOUT" 'STUB-SECRET-VALUE'

# ============================================================================
log_section "Summary"
# ============================================================================
echo "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if (( TESTS_FAILED > 0 )); then
    echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
    exit 1
fi
echo -e "Tests failed: ${TESTS_FAILED}"
echo ""
log_success "All starter-hub config-generation tests passed."
