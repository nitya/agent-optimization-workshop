#!/usr/bin/env bash
# 01-provision.sh — provision the fundamentals slice of Contoso Travel.
#
# Idempotent. Safe to re-run at any point.
#
# Why azd (not a hand-rolled az script)?
#   - The repo's infra/main.bicep already declares the full Foundry setup —
#     RG, account, project, both model deployments, Log Analytics,
#     App Insights, storage, connections, and user RBAC.
#   - Bicep's deterministic resource-token is what lets
#     02-enable-hosted-infra.sh (and 03-capstone-agent.sh)
#     re-provision the SAME RG later with ENABLE_HOSTED_AGENTS=true and only
#     add hosted-agent modules — a shell provisioner would need to stitch
#     that state itself.
#   - If we were building prompt agents only, `az` commands or a simpler
#     "standard agents" azd template would be enough. Our goal is one
#     template that supports the hosted-agent capstone later, so we use
#     the same Bicep here.
#
# What it does:
#   1. Confirms az + azd are signed in.
#   2. Picks a unique environment suffix (random 4-hex by default) → azd env
#      name contoso-travel-<suffix> and RG rg-contoso-travel-<suffix>.
#   3. Creates the azd env if missing and pins AZURE_RESOURCE_GROUP,
#      AZURE_LOCATION, and ENABLE_HOSTED_AGENTS=false.
#   4. Runs `azd provision` if the resource group is missing.
#   5. Verifies developer RBAC (Azure AI User, Foundry Project Manager,
#      Storage Blob Data Contributor) at the RG scope.
#   6. Writes .env at repo root from sample.env, filled in with values
#      read from `azd env get-values`.
#
# What it does NOT do:
#   - Install tools or extensions (run ./00-quickstart.sh first).
#   - Log you in without prompting.
#   - Purge soft-deleted resources for you (prints the command).
#   - Provision hosted-agent extras (ACR, capability host). For that,
#     run ./02-enable-hosted-infra.sh (adds ACR + capability host) and then
#     ./03-capstone-agent.sh (scaffolds and deploys the Capstone hosted agent).
#
# Env vars (all optional):
#   AZD_ENV_SUFFIX  4-char token added to env + RG names. Default: random hex.
#   AZURE_LOCATION  Deployment region. Default: eastus2.
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

# ---------- flags ----------
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

# ---------- output helpers ----------
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

# ---------- context ----------
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
AZURE_LOCATION="${AZURE_LOCATION:-eastus2}"

# Default suffix: a fresh random 4-hex token so every run gets a new env
# (and a new Bicep resource-token). Users can override with AZD_ENV_SUFFIX.
SUFFIX_SOURCE="random"
if [[ -n "${AZD_ENV_SUFFIX:-}" ]]; then
    SUFFIX_SOURCE="AZD_ENV_SUFFIX env var"
else
    AZD_ENV_SUFFIX=$(openssl rand -hex 2 2>/dev/null || printf '%04x' $((RANDOM % 65536)))
fi

# If the chosen suffix already collides (azd env exists OR RG exists OR soft-
# deleted account exists), append a random 2-hex tail. Repeat if needed.
choose_suffix() {
    local base="${1:-$AZD_ENV_SUFFIX}"
    local candidate="$base"
    local attempt=0
    while true; do
        local env_dir="$REPO_ROOT/.azure/contoso-travel-$candidate"
        local rg="rg-contoso-travel-$candidate"
        local rg_exists soft
        rg_exists=$(az group exists --name "$rg" 2>/dev/null || echo "false")
        soft=$(az cognitiveservices account list-deleted \
            --query "[?resourceGroup=='$rg'].name" -o tsv 2>/dev/null || true)
        if [[ ! -d "$env_dir" && "$rg_exists" != "true" && -z "$soft" ]]; then
            echo "$candidate"
            return
        fi
        attempt=$((attempt+1))
        [[ $attempt -gt 20 ]] && { echo "$candidate"; return; }
        candidate="$base-$(openssl rand -hex 1 2>/dev/null || echo $RANDOM | cut -c1-2)"
    done
}

# Only auto-avoid collisions when the suffix was auto-generated. If the user
# explicitly passed AZD_ENV_SUFFIX, trust them — they're reusing an existing env.
if [[ "$SUFFIX_SOURCE" == "random" ]]; then
    AZD_ENV_SUFFIX=$(choose_suffix "$AZD_ENV_SUFFIX")
fi
AZD_ENV_NAME="contoso-travel-$AZD_ENV_SUFFIX"
RG_NAME="rg-$AZD_ENV_NAME"

section "0. Context"
pass "azd env name: $AZD_ENV_NAME"
pass "resource group: $RG_NAME"
pass "location: $AZURE_LOCATION"
pass "suffix source: $SUFFIX_SOURCE"
detail "each run gets a fresh random suffix by default — override with AZD_ENV_SUFFIX=<4-char> to reuse an env"
pass "repo root: $REPO_ROOT"

# ---------- 1. auth prereq ----------
section "1. Auth prerequisites"

if ! command -v az >/dev/null 2>&1; then
    fail "az missing (run ./00-quickstart.sh first)"
elif ! az account show >/dev/null 2>&1; then
    fail "az not signed in (run 'az login' or ./00-quickstart.sh)"
else
    sub=$(az account show --query "name" -o tsv 2>/dev/null || echo "?")
    pass "az signed in"
    detail "subscription: $sub"
fi

if ! command -v azd >/dev/null 2>&1; then
    fail "azd missing (run ./00-quickstart.sh first)"
elif azd auth status 2>/dev/null | grep -qi "not logged in"; then
    fail "azd not signed in (run 'azd auth login' or ./00-quickstart.sh)"
else
    pass "azd signed in"
fi

if (( FAILED > 0 )); then
    printf "\n%s==>%s %sSummary%s\n" "$BLUE" "$RESET" "$BOLD" "$RESET"
    printf "  %s✗%s auth prerequisites not met. address the failures above and re-run.\n" "$RED" "$RESET"
    exit 1
fi

# ---------- 2. azd env ----------
section "2. azd environment"

if [[ -d "$REPO_ROOT/.azure/$AZD_ENV_NAME" ]]; then
    pass "azd env '$AZD_ENV_NAME' exists"
else
    fail "azd env '$AZD_ENV_NAME' missing"
    if ask_yes "run 'azd env new $AZD_ENV_NAME' now?"; then
        sub_id=$(az account show --query id -o tsv 2>/dev/null || true)
        if (cd "$REPO_ROOT" && azd env new "$AZD_ENV_NAME" \
                --subscription "$sub_id" \
                --location "$AZURE_LOCATION"); then
            pass "azd env '$AZD_ENV_NAME' created"
            FAILED=$((FAILED-1))
        else
            detail "azd env new failed; run manually"
        fi
    fi
fi

# Pin env variables so azd Bicep receives them consistently on every provision.
if [[ -d "$REPO_ROOT/.azure/$AZD_ENV_NAME" ]]; then
    (cd "$REPO_ROOT" && azd env select "$AZD_ENV_NAME" >/dev/null 2>&1 || true)
    (cd "$REPO_ROOT" && azd env set AZURE_LOCATION "$AZURE_LOCATION" >/dev/null 2>&1 || true)
    (cd "$REPO_ROOT" && azd env set AZURE_RESOURCE_GROUP "$RG_NAME" >/dev/null 2>&1 || true)
    (cd "$REPO_ROOT" && azd env set ENABLE_HOSTED_AGENTS false >/dev/null 2>&1 || true)
    pass "pinned AZURE_LOCATION, AZURE_RESOURCE_GROUP, ENABLE_HOSTED_AGENTS=false"
fi

# ---------- 3. provision ----------
section "3. Provisioning (fundamentals slice)"

rg_exists=$(az group exists --name "$RG_NAME" 2>/dev/null || echo "false")
if [[ "$rg_exists" == "true" ]]; then
    pass "resource group '$RG_NAME' exists"
    detail "skipping azd provision (already provisioned)"
else
    fail "resource group '$RG_NAME' missing"
    if ask_yes "run 'azd provision' now? (~2-3 minutes, creates paid Azure resources)"; then
        if (cd "$REPO_ROOT" && azd provision); then
            pass "azd provision complete"
            FAILED=$((FAILED-1))
        else
            detail "azd provision failed; run manually and see labs/TROUBLESHOOTING.md"
        fi
    fi
fi

# ---------- 4. verify user RBAC ----------
section "4. Developer RBAC (post-provision check)"

user_oid=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
rg_exists=$(az group exists --name "$RG_NAME" 2>/dev/null || echo "false")

if [[ -z "$user_oid" || "$rg_exists" != "true" ]]; then
    warn "skipping RBAC verification (RG missing or user id unknown)"
else
    # Bicep assigns these roles at nested scopes (Foundry account, project,
    # storage). List all of the user's assignments and match anything scoped
    # under this RG. Filter in shell because ARM sometimes returns
    # 'resourcegroups' (lowercase), which trips a case-sensitive JMESPath contains().
    assignments=$(az role assignment list \
        --assignee "$user_oid" --all \
        --query "[].[roleDefinitionName, scope]" -o tsv 2>/dev/null \
        | awk -F'\t' -v rg="$RG_NAME" 'tolower($2) ~ tolower(rg) {print $1}' || true)

    scope="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG_NAME"
    declare -a wanted=(
        "Foundry User"
        "Foundry Project Manager"
    )
    for role in "${wanted[@]}"; do
        if echo "$assignments" | grep -qxF "$role"; then
            pass "$role"
        else
            warn "$role not found under $RG_NAME"
            detail "az role assignment create --assignee $user_oid --role '$role' --scope $scope"
        fi
    done
fi

# ---------- 5. write .env from sample.env ----------
section "5. Populate .env"

if [[ ! -f "$REPO_ROOT/sample.env" ]]; then
    warn "sample.env not found at repo root; skipping .env generation"
else
    tmp=$(mktemp)
    declare -A vals=()

    if [[ -d "$REPO_ROOT/.azure/$AZD_ENV_NAME" ]]; then
        while IFS='=' read -r k v; do
            [[ -z "$k" ]] && continue
            v="${v%\"}"; v="${v#\"}"
            vals[$k]="$v"
        done < <(cd "$REPO_ROOT" && azd env get-values -e "$AZD_ENV_NAME" 2>/dev/null || true)
    fi

    # Enrich with values azd may not emit.
    vals[AZD_ENV_NAME]="$AZD_ENV_NAME"
    vals[AZURE_ENV_NAME]="$AZD_ENV_NAME"
    vals[AZURE_RESOURCE_GROUP]="$RG_NAME"
    vals[AZURE_LOCATION]="${vals[AZURE_LOCATION]:-$AZURE_LOCATION}"
    vals[AZURE_SUBSCRIPTION_ID]="${vals[AZURE_SUBSCRIPTION_ID]:-$(az account show --query id -o tsv 2>/dev/null || true)}"
    vals[AZURE_TENANT_ID]="${vals[AZURE_TENANT_ID]:-$(az account show --query tenantId -o tsv 2>/dev/null || true)}"

    while IFS= read -r line; do
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)= ]]; then
            key="${BASH_REMATCH[1]}"
            new="${vals[$key]:-}"
            if [[ -n "$new" ]]; then
                echo "$key=$new"
            else
                # Preserve template default if present.
                echo "$line"
            fi
        else
            echo "$line"
        fi
    done < "$REPO_ROOT/sample.env" > "$tmp"

    mv "$tmp" "$REPO_ROOT/.env"
    pass ".env written at $REPO_ROOT/.env"
    detail "review before committing — this file contains subscription and tenant IDs"
fi

# ---------- summary ----------
printf "\n%s==>%s %sSummary%s\n" "$BLUE" "$RESET" "$BOLD" "$RESET"
if (( FAILED == 0 && WARNED == 0 )); then
    printf "  %s✓%s fundamentals ready. next: open the Foundry portal for §7.2.\n" "$GREEN" "$RESET"
    printf "         when you reach the capstone, run: ./labs/_devguide/02-enable-hosted-infra.sh then ./03-capstone-agent.sh\n"
    printf "\n         to reuse this env in a later shell:\n"
    printf "             %sAZD_ENV_SUFFIX=%s ./labs/_devguide/01-provision.sh%s\n" "$BOLD" "$AZD_ENV_SUFFIX" "$RESET"
    exit 0
elif (( FAILED == 0 )); then
    printf "  %s!%s fundamentals ready with warnings above.\n" "$YELLOW" "$RESET"
    printf "\n         to reuse this env in a later shell:\n"
    printf "             %sAZD_ENV_SUFFIX=%s ./labs/_devguide/01-provision.sh%s\n" "$BOLD" "$AZD_ENV_SUFFIX" "$RESET"
    exit 0
else
    printf "  %s✗%s %d step(s) failed. address them, then re-run this script.\n" "$RED" "$RESET" "$FAILED"
    exit 1
fi
