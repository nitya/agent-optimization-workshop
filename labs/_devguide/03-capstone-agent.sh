#!/usr/bin/env bash
# 03-capstone-agent.sh — scaffold + deploy a NEW hosted agent for the capstone.
#
# STATUS: STUB. Untested end-to-end. Test plan lives in session memory.
#
# Idempotent goal (not yet verified): safe to re-run. On repeat runs it should
# detect the already-scaffolded folder, the existing azd service entry, and the
# deployed agent, then skip past those steps.
#
# Why a separate script (not 02-hosted-agent.sh)?
#   - 02-hosted-agent.sh deploys the ORIGINAL prompt-agent-turned-hosted at
#     `src/`. That agent stays as the fundamentals + core baseline.
#   - The capstone story wants a FRESH scaffold produced by the microsoft-foundry
#     `create` sub-skill, landing in `src-capstone/`, and registered as a new
#     azd service so both agents coexist in the same Foundry project.
#   - Bicep is unchanged. Same RG. Same Foundry project. Same reuse guarantee.
#
# Prerequisites:
#   - 01-provision.sh has been run (Foundry account + project + models exist).
#   - 02-hosted-agent.sh has been run at least once (ENABLE_HOSTED_AGENTS=true,
#     ACR + capability host exist).
#
# What it does:
#   1. Resolves the target azd env (most-recent contoso-travel-* or $AZD_ENV_NAME).
#   2. Confirms hosted-agent infra is in place.
#   3. Scaffolds a new hosted agent into $CAPSTONE_SRC_DIR (default: src-capstone)
#      via `azd ai agent init --project-id <existing project>`.
#   4. Appends a new service block to azure.yaml pointing at that folder.
#   5. Deploys with `azd deploy <capstone-service>`.
#
# What it does NOT do (yet):
#   - Non-interactive sample selection. Sample choice is architectural; the
#     script prints the catalog and asks. Later we can pin a specific manifest.
#   - Teardown of the capstone service.
#   - Verify the original agent still deploys after capstone is added.
#
# Env vars (all optional):
#   AZD_ENV_NAME         Explicit azd env. Default: most-recent contoso-travel-*.
#   CAPSTONE_SERVICE     Name of the new azd service. Default:
#                        contoso-travel-concierge-capstone.
#   CAPSTONE_SRC_DIR     Folder to scaffold into. Default: src-capstone.
#   CAPSTONE_SAMPLE_URL  If set, skip the sample-selection prompt and use this.
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
CAPSTONE_SERVICE="${CAPSTONE_SERVICE:-contoso-travel-concierge-capstone}"
CAPSTONE_SRC_DIR="${CAPSTONE_SRC_DIR:-src-capstone}"

# ---------- 0. resolve env ----------
section "0. Resolve target azd env"

if [[ -z "${AZD_ENV_NAME:-}" ]]; then
    if [[ -d "$REPO_ROOT/.azure" ]]; then
        AZD_ENV_NAME=$(ls -1t "$REPO_ROOT/.azure" 2>/dev/null | grep '^contoso-travel-' | head -n1 || true)
    fi
fi

if [[ -z "$AZD_ENV_NAME" || ! -d "$REPO_ROOT/.azure/$AZD_ENV_NAME" ]]; then
    fail "no azd env found. run ./01-provision.sh first."
    exit 1
fi

RG_NAME="rg-$AZD_ENV_NAME"
pass "azd env: $AZD_ENV_NAME"
pass "resource group: $RG_NAME"
pass "capstone service name: $CAPSTONE_SERVICE"
pass "capstone src folder: $CAPSTONE_SRC_DIR"

# ---------- 1. prerequisites ----------
section "1. Prerequisites"

if ! az account show >/dev/null 2>&1 || azd auth status 2>/dev/null | grep -qi "not logged in"; then
    fail "az or azd not signed in (run ./00-quickstart.sh)"
fi

hosted_flag=$(cd "$REPO_ROOT" && azd env get-value ENABLE_HOSTED_AGENTS 2>/dev/null || echo "false")
if [[ "$hosted_flag" != "true" ]]; then
    fail "ENABLE_HOSTED_AGENTS is not true on '$AZD_ENV_NAME'. run ./02-hosted-agent.sh first."
fi

project_id=$(cd "$REPO_ROOT" && azd env get-value AZURE_AI_PROJECT_ID 2>/dev/null || true)
if [[ -z "$project_id" ]]; then
    fail "AZURE_AI_PROJECT_ID not set on '$AZD_ENV_NAME'. re-run ./01-provision.sh."
fi

if (( FAILED > 0 )); then
    printf "\n%s==>%s %sSummary%s\n" "$BLUE" "$RESET" "$BOLD" "$RESET"
    printf "  %s✗%s prerequisites not met. address the failures above and re-run.\n" "$RED" "$RESET"
    exit 1
fi

pass "hosted-agent infra ready"
detail "project id: $project_id"

# ---------- 2. sample selection ----------
section "2. Sample selection"

if [[ -z "${CAPSTONE_SAMPLE_URL:-}" ]]; then
    warn "no CAPSTONE_SAMPLE_URL provided"
    detail "list available samples with:"
    detail "  azd ai agent sample list --language python --output json"
    detail "then re-run with:"
    detail "  CAPSTONE_SAMPLE_URL=<manifestUrl> ./labs/_devguide/03-capstone-agent.sh"
    detail "or continue and pick interactively via 'azd ai agent init' below."
else
    pass "sample manifest: $CAPSTONE_SAMPLE_URL"
fi

# ---------- 3. scaffold ----------
section "3. Scaffold via 'azd ai agent init'"

if [[ -d "$REPO_ROOT/$CAPSTONE_SRC_DIR" ]]; then
    pass "$CAPSTONE_SRC_DIR already scaffolded"
    detail "skipping azd ai agent init (folder exists)"
else
    fail "$CAPSTONE_SRC_DIR missing"
    if ask_yes "scaffold $CAPSTONE_SRC_DIR now?"; then
        cmd=(azd ai agent init
             --deploy-mode code
             --runtime python_3_13
             --entry-point main.py
             --src "$CAPSTONE_SRC_DIR"
             --project-id "$project_id")
        [[ -n "${CAPSTONE_SAMPLE_URL:-}" ]] && cmd+=(-m "$CAPSTONE_SAMPLE_URL")
        if (cd "$REPO_ROOT" && "${cmd[@]}"); then
            pass "$CAPSTONE_SRC_DIR scaffolded"
            FAILED=$((FAILED-1))
        else
            detail "azd ai agent init failed; run manually and re-invoke this script"
        fi
    fi
fi

# ---------- 4. register service in azure.yaml ----------
section "4. Register '$CAPSTONE_SERVICE' in azure.yaml"

if grep -qE "^  ${CAPSTONE_SERVICE}:" "$REPO_ROOT/azure.yaml"; then
    pass "'$CAPSTONE_SERVICE' already present in azure.yaml"
else
    warn "'$CAPSTONE_SERVICE' not in azure.yaml"
    detail "TODO: append a service block matching the shape of contoso-travel-concierge,"
    detail "with 'project: $CAPSTONE_SRC_DIR' and 'name: $CAPSTONE_SERVICE'."
    detail "(the scaffold command above may have done this — verify before continuing)"
fi

# ---------- 5. deploy ----------
section "5. Deploy '$CAPSTONE_SERVICE'"

if ask_yes "run 'azd deploy $CAPSTONE_SERVICE' now? (~3-5 minutes)"; then
    if (cd "$REPO_ROOT" && azd deploy "$CAPSTONE_SERVICE"); then
        pass "$CAPSTONE_SERVICE deployed"
    else
        fail "azd deploy $CAPSTONE_SERVICE failed"
        detail "check azure.yaml has the '$CAPSTONE_SERVICE' service block"
    fi
else
    warn "skipped azd deploy"
fi

# ---------- summary ----------
printf "\n%s==>%s %sSummary%s\n" "$BLUE" "$RESET" "$BOLD" "$RESET"
if (( FAILED == 0 && WARNED == 0 )); then
    printf "  %s✓%s capstone hosted agent scaffolded and deployed.\n" "$GREEN" "$RESET"
    detail "the original '$CAPSTONE_SERVICE'-adjacent agent from ./src is untouched."
    exit 0
elif (( FAILED == 0 )); then
    printf "  %s!%s capstone step complete with warnings above.\n" "$YELLOW" "$RESET"
    exit 0
else
    printf "  %s✗%s %d step(s) failed. address them, then re-run this script.\n" "$RED" "$RESET" "$FAILED"
    exit 1
fi
