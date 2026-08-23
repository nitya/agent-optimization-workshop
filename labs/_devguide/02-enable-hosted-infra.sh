#!/usr/bin/env bash
# 02-enable-hosted-infra.sh — add hosted-agent infra to the SAME azd env.
#
# Idempotent. Safe to re-run. Reuses the resource group and Foundry account
# already created by 01-provision.sh — Bicep's deterministic resource-token
# means existing resources are recognized and left alone. Only the modules
# gated on ENABLE_HOSTED_AGENTS=true (ACR, capability host, ACR role
# assignments) are added.
#
# What it does:
#   1. Confirms auth + a target azd env from 01-provision.sh.
#   2. Sets ENABLE_HOSTED_AGENTS=true on that env.
#   3. Runs `azd provision` to add the hosted-agent modules.
#   4. Verifies developer RBAC still includes Storage/AI/Foundry roles.
#   5. Refreshes .env with the new hosted-agent env values.
#
# What it does NOT do:
#   - Deploy any hosted agent code. The workshop deploys the CAPSTONE
#     hosted agent (scaffolded fresh into src-capstone/) via
#     ./03-capstone-agent.sh — run that AFTER this script succeeds.
#
# Env vars:
#   AZD_ENV_NAME  Explicit azd env name. If not set, uses the most recent
#                 contoso-travel-* env under .azure/.
#
# Flags:
#   --yes    Auto-answer yes to prompts.
#   --quiet  Only print failing checks and the summary.
#   --help   Print this header.
#
# Exit codes:
#   0  All steps succeeded (or were already done).
#   1  A step failed and requires manual action.
#   2  Bad flag.

set -uo pipefail

ASSUME_YES=0
QUIET=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        --quiet|-q) QUIET=1 ;;
        --help|-h) grep '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BLUE=$'\033[34m'
else
    BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""; RED=""; BLUE=""
fi

FAILED=0
WARNED=0

section() { (( QUIET )) && return; printf "\n%s==>%s %s%s%s\n" "$BLUE" "$RESET" "$BOLD" "$1" "$RESET"; }
pass()    { (( QUIET )) && return; printf "  %s✓%s %s\n" "$GREEN" "$RESET" "$1"; }
warn()    { WARNED=$((WARNED+1)); printf "  %s!%s %s\n" "$YELLOW" "$RESET" "$1"; }
fail()    { FAILED=$((FAILED+1)); printf "  %s✗%s %s\n" "$RED" "$RESET" "$1"; }
detail()  { (( QUIET )) && return; printf "    %s%s%s\n" "$DIM" "$1" "$RESET"; }

ask_yes() {
    local prompt=$1
    if (( ASSUME_YES )); then
        printf "    %s(auto-yes)%s %s\n" "$DIM" "$RESET" "$prompt"
        return 0
    fi
    local answer
    read -r -p "    ${prompt} [y/N] " answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# ---------- 0. resolve env ----------
section "0. Resolve target azd env"

if [[ -z "${AZD_ENV_NAME:-}" ]]; then
    if [[ -d "$REPO_ROOT/.azure" ]]; then
        AZD_ENV_NAME=$(ls -1t "$REPO_ROOT/.azure" 2>/dev/null | grep '^contoso-travel-' | head -n1 || true)
    fi
fi

if [[ -z "$AZD_ENV_NAME" || ! -d "$REPO_ROOT/.azure/$AZD_ENV_NAME" ]]; then
    fail "no azd env found. run ./01-provision.sh first, or set AZD_ENV_NAME."
    exit 1
fi

RG_NAME="rg-$AZD_ENV_NAME"
pass "using azd env '$AZD_ENV_NAME'"
pass "resource group: $RG_NAME"

# ---------- 1. auth ----------
section "1. Auth prerequisites"

if ! az account show >/dev/null 2>&1; then
    fail "az not signed in"
elif azd auth status 2>/dev/null | grep -qi "not logged in"; then
    fail "azd not signed in"
else
    pass "az + azd signed in"
fi

if (( FAILED > 0 )); then
    printf "\n%s==>%s %sSummary%s\n" "$BLUE" "$RESET" "$BOLD" "$RESET"
    printf "  %s✗%s auth prerequisites not met. run ./00-quickstart.sh, then re-run.\n" "$RED" "$RESET"
    exit 1
fi

# ---------- 2. flip flag ----------
section "2. Enable hosted-agent modules"

(cd "$REPO_ROOT" && azd env select "$AZD_ENV_NAME" >/dev/null 2>&1 || true)
(cd "$REPO_ROOT" && azd env set ENABLE_HOSTED_AGENTS true >/dev/null 2>&1 || true)
pass "ENABLE_HOSTED_AGENTS=true set on '$AZD_ENV_NAME'"

# ---------- 3. re-provision ----------
section "3. Re-provision (adds ACR, capability host, hosted-agent RBAC)"

if ask_yes "run 'azd provision' now? (~2 minutes; reuses existing Foundry resources)"; then
    if (cd "$REPO_ROOT" && azd provision); then
        pass "azd provision complete (hosted-agent modules added)"
    else
        fail "azd provision failed; see labs/TROUBLESHOOTING.md"
    fi
else
    warn "skipped azd provision — capstone deploy will fail without it"
fi

# ---------- 4. verify RBAC ----------
section "4. Developer RBAC (post-provision check)"

user_oid=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
scope="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG_NAME"

# Bicep assigns these roles at nested scopes (account, project, storage).
# ARM sometimes returns 'resourcegroups' lowercased in the scope string, so we
# filter in shell (case-insensitive) instead of via JMESPath contains().
assignments=$(az role assignment list \
    --assignee "$user_oid" --all \
    --query "[].[roleDefinitionName, scope]" -o tsv 2>/dev/null \
    | awk -F'\t' -v rg="$RG_NAME" 'tolower($2) ~ tolower(rg) {print $1}' || true)

declare -a wanted=(
    "Foundry User"
    "Foundry Project Manager"
    "Storage Blob Data Contributor"
)
for role in "${wanted[@]}"; do
    if echo "$assignments" | grep -qxF "$role"; then
        pass "$role"
    else
        warn "$role not found under $RG_NAME"
        detail "az role assignment create --assignee $user_oid --role '$role' --scope $scope"
    fi
done

# ---------- 5. refresh .env ----------
section "5. Refresh .env"

if [[ -f "$REPO_ROOT/sample.env" ]]; then
    tmp=$(mktemp)
    declare -A vals=()
    while IFS='=' read -r k v; do
        [[ -z "$k" ]] && continue
        v="${v%\"}"; v="${v#\"}"
        vals[$k]="$v"
    done < <(cd "$REPO_ROOT" && azd env get-values -e "$AZD_ENV_NAME" 2>/dev/null || true)

    vals[AZD_ENV_NAME]="$AZD_ENV_NAME"
    vals[AZURE_ENV_NAME]="$AZD_ENV_NAME"
    vals[AZURE_RESOURCE_GROUP]="$RG_NAME"
    vals[ENABLE_HOSTED_AGENTS]="true"

    while IFS= read -r line; do
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)= ]]; then
            key="${BASH_REMATCH[1]}"
            new="${vals[$key]:-}"
            if [[ -n "$new" ]]; then
                echo "$key=$new"
            else
                echo "$line"
            fi
        else
            echo "$line"
        fi
    done < "$REPO_ROOT/sample.env" > "$tmp"
    mv "$tmp" "$REPO_ROOT/.env"
    pass ".env refreshed at $REPO_ROOT/.env"
else
    warn "sample.env not found; skipping .env refresh"
fi

# ---------- summary ----------
printf "\n%s==>%s %sSummary%s\n" "$BLUE" "$RESET" "$BOLD" "$RESET"
if (( FAILED == 0 && WARNED == 0 )); then
    printf "  %s✓%s hosted-agent infra ready. next: ./labs/_devguide/03-capstone-agent.sh\n" "$GREEN" "$RESET"
    exit 0
elif (( FAILED == 0 )); then
    printf "  %s!%s hosted-agent infra ready with warnings above.\n" "$YELLOW" "$RESET"
    exit 0
else
    printf "  %s✗%s %d step(s) failed. address them, then re-run this script.\n" "$RED" "$RESET" "$FAILED"
    exit 1
fi
