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
# gce-demo-telemetry-sa.sh behavior test (hermetic)
# =================================================
# Exercises the telemetry-SA script with a fully stubbed `gcloud` on PATH — no
# live GCP. The stub records every invocation and lets each case program the
# outcome of `keys create`, so the tests can pin the org-policy tolerance:
#
#   - default             -> downloads a key, prints "upload the key" next steps
#   - org policy denies    -> falls back to KEYLESS (no key, exit 0, guidance)
#     key creation           [constraints/iam.disableServiceAccountKeyCreation]
#   - TELEMETRY_KEYLESS=true -> never even calls `keys create`
#   - any other key error  -> still fails hard (exit non-zero)
#
# Usage:
#   ./scripts/starter-hub/gce-demo-telemetry-sa-test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/gce-demo-telemetry-sa.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0

log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1"; }
log_section() { echo ""; echo -e "${BLUE}=== $1 ===${NC}"; }

assert_contains() {
    local d="$1" hay="$2" needle="$3"; TESTS_RUN=$((TESTS_RUN+1))
    if printf '%s' "$hay" | grep -qiF -- "$needle"; then
        log_success "$d"; TESTS_PASSED=$((TESTS_PASSED+1))
    else
        log_error "$d"; log_error "  expected to contain: $needle"
        printf '%s\n' "$hay" | sed 's/^/    /'; TESTS_FAILED=$((TESTS_FAILED+1))
    fi
}
assert_not_contains() {
    local d="$1" hay="$2" needle="$3"; TESTS_RUN=$((TESTS_RUN+1))
    if printf '%s' "$hay" | grep -qiF -- "$needle"; then
        log_error "$d"; log_error "  expected NOT to contain: $needle"; TESTS_FAILED=$((TESTS_FAILED+1))
    else
        log_success "$d"; TESTS_PASSED=$((TESTS_PASSED+1))
    fi
}
assert_eq() {
    local d="$1" exp="$2" act="$3"; TESTS_RUN=$((TESTS_RUN+1))
    if [[ "$exp" == "$act" ]]; then
        log_success "$d"; TESTS_PASSED=$((TESTS_PASSED+1))
    else
        log_error "$d"; log_error "  expected: '$exp'  actual: '$act'"; TESTS_FAILED=$((TESTS_FAILED+1))
    fi
}
assert_file_absent() {
    local d="$1" f="$2"; TESTS_RUN=$((TESTS_RUN+1))
    if [[ -e "$f" ]]; then log_error "$d (exists: $f)"; TESTS_FAILED=$((TESTS_FAILED+1));
    else log_success "$d"; TESTS_PASSED=$((TESTS_PASSED+1)); fi
}
assert_file_present() {
    local d="$1" f="$2"; TESTS_RUN=$((TESTS_RUN+1))
    if [[ -e "$f" ]]; then log_success "$d"; TESTS_PASSED=$((TESTS_PASSED+1));
    else log_error "$d (missing: $f)"; TESTS_FAILED=$((TESTS_FAILED+1)); fi
}

STUB_BIN="$(mktemp -d)"
trap '[ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"; [ -n "${WORK_ROOT:-}" ] && rm -rf "$WORK_ROOT"' EXIT

# gcloud stub: records calls to $STUB_CALLLOG; programs `keys create` via
# $STUB_KEYS_CREATE_MODE (ok|policy_denied|other_error). `describe` returns 0
# (SA exists) so the script skips its create+sleep.
cat > "${STUB_BIN}/gcloud" <<'STUB'
#!/bin/bash
[[ -n "${STUB_CALLLOG:-}" ]] && echo "$*" >> "$STUB_CALLLOG"
# `gcloud iam service-accounts <verb> ...` — verb is $3.
if [[ "$1 $2" == "iam service-accounts" ]]; then
    case "$3" in
        keys)
            # keys create <FILE> --iam-account <EMAIL>  ->  $4=create $5=<FILE>
            keyfile="$5"
            case "${STUB_KEYS_CREATE_MODE:-ok}" in
                ok) echo '{"type":"service_account"}' > "$keyfile"; exit 0 ;;
                policy_denied)
                    echo "ERROR: (gcloud.iam.service-accounts.keys.create) FAILED_PRECONDITION: Key creation is not allowed on this service account. Constraint constraints/iam.disableServiceAccountKeyCreation enforced." >&2
                    exit 1 ;;
                other_error)
                    echo "ERROR: (gcloud.iam.service-accounts.keys.create) PERMISSION_DENIED: some unrelated failure" >&2
                    exit 1 ;;
            esac ;;
        describe) exit 0 ;;      # SA already exists (script skips create+sleep)
        create)   exit 0 ;;
        delete)   exit 0 ;;
    esac
fi
case "$1 $2" in
    "services enable")                    exit 0 ;;
    "projects add-iam-policy-binding")    exit 0 ;;
    "projects remove-iam-policy-binding") exit 0 ;;
    "projects get-iam-policy")            echo ""; exit 0 ;;
    "config get-value")                   echo "${STUB_GCLOUD_PROJECT:-}"; exit 0 ;;
esac
exit 0
STUB
chmod +x "${STUB_BIN}/gcloud"
export PATH="${STUB_BIN}:${PATH}"

WORK_ROOT="$(mktemp -d)"

# run_sa <case-subdir> — run the target in an isolated CWD; echoes combined output.
# Caller sets STUB_KEYS_CREATE_MODE / TELEMETRY_KEYLESS in the environment.
run_sa() {
    local sub="$1"; shift
    local wd="${WORK_ROOT}/${sub}"
    mkdir -p "$wd"
    (
        cd "$wd" || exit 99
        export PROJECT_ID="test-proj"
        export STUB_CALLLOG="${wd}/calls.log"
        : > "$STUB_CALLLOG"
        bash "$TARGET" "$@" 2>&1
    )
}

# ============================================================================
log_section "default: key creation succeeds"
# ============================================================================
OUT="$(STUB_KEYS_CREATE_MODE=ok run_sa ok)"; RC=$?
assert_eq "exit 0 on success" 0 "$RC"
assert_file_present "downloads the JSON key" "${WORK_ROOT}/ok/.scratch/telemetry-gcp-credentials.json"
assert_contains "prints key-upload next steps" "$OUT" "Upload the key to the Hub"
assert_not_contains "no keyless banner on the happy path" "$OUT" "keyless"

# ============================================================================
log_section "org policy denies key creation -> keyless fallback"
# ============================================================================
OUT="$(STUB_KEYS_CREATE_MODE=policy_denied run_sa denied)"; RC=$?
assert_eq "exits 0 (graceful, not a hard failure)" 0 "$RC"
assert_file_absent "no key file left behind" "${WORK_ROOT}/denied/.scratch/telemetry-gcp-credentials.json"
assert_contains "explains the org policy" "$OUT" "disableServiceAccountKeyCreation"
assert_contains "falls back to keyless" "$OUT" "keyless"
assert_contains "keyless guidance mentions ADC" "$OUT" "Application Default Credentials"
assert_contains "keyless still succeeds overall" "$OUT" "=== Success ==="

# ============================================================================
log_section "TELEMETRY_KEYLESS=true never attempts key creation"
# ============================================================================
OUT="$(STUB_KEYS_CREATE_MODE=ok TELEMETRY_KEYLESS=true run_sa keyless)"; RC=$?
CALLS="$(cat "${WORK_ROOT}/keyless/calls.log" 2>/dev/null || true)"
assert_eq "exit 0 in keyless mode" 0 "$RC"
assert_file_absent "no key file in keyless mode" "${WORK_ROOT}/keyless/.scratch/telemetry-gcp-credentials.json"
assert_not_contains "gcloud keys create was NOT called" "$CALLS" "keys create"
assert_contains "still grants roles (add-iam-policy-binding called)" "$CALLS" "add-iam-policy-binding"

# ============================================================================
log_section "unrelated key error still fails hard"
# ============================================================================
OUT="$(STUB_KEYS_CREATE_MODE=other_error run_sa other)"; RC=$?
assert_eq "non-zero exit on a non-policy error" 1 "$RC"
assert_not_contains "does NOT masquerade as keyless" "$OUT" "Falling back to keyless"

# ============================================================================
log_section "Summary"
# ============================================================================
echo "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if (( TESTS_FAILED > 0 )); then
    echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"; exit 1
fi
echo "Tests failed: 0"; echo ""
log_success "All telemetry-SA tolerance tests passed."
