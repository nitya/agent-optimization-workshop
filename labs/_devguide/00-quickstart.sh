#!/usr/bin/env bash
# 00-quickstart.sh — verify workshop prerequisites and starting state.
#
# Idempotent. Safe to re-run at any point in the workshop.
#
# What it checks:
#   1. Tools:  python, az, azd, gh, copilot
#   2. azd extensions: azure.ai.agents, azure.ai.projects, azure.ai.inspector
#   3. Auth:   az account, azd auth
#   4. State:  .azure/ folder, .env file at repo root
#
# What it does NOT do:
#   - Install missing tools.
#   - Log you in without prompting.
#   - Delete .azure/ or .env for you.
#   - Provision Azure resources. For that, run 01-provision.sh.
#
# Flags:
#   --yes    Auto-answer "yes" to prompts (install extensions, run az/azd login).
#   --quiet  Only print failing checks and the final summary.
#
# Exit codes:
#   0  All checks passed (or fixed during the run).
#   1  One or more checks failed and require manual action.

set -uo pipefail

# ---------- flags ----------
ASSUME_YES=0
QUIET=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        --quiet|-q) QUIET=1 ;;
        --help|-h)
            grep '^# ' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown flag: $arg" >&2
            exit 2
            ;;
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
    # ask_yes "prompt"  -> 0 for yes, 1 for no
    local prompt=$1
    if (( ASSUME_YES )); then
        printf "    %s(auto-yes)%s %s\n" "$DIM" "$RESET" "$prompt"
        return 0
    fi
    local answer
    read -r -p "    ${prompt} [y/N] " answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

# ---------- 1. tools ----------
check_tool() {
    # check_tool "name" "cmd" "version-args"
    local name=$1 cmd=$2 version_args=$3
    if ! command -v "$cmd" >/dev/null 2>&1; then
        fail "$name not found on PATH"
        detail "install $name before continuing"
        return
    fi
    # shellcheck disable=SC2086
    local out
    out=$("$cmd" $version_args 2>&1 | head -n 3 | tr -d '\r')
    pass "$name present"
    detail "$out"
}

section "1. Tools"
check_tool "python"  "python"  "--version"
check_tool "az"      "az"      "version"
check_tool "azd"     "azd"     "version"
check_tool "gh"      "gh"      "--version"
check_tool "copilot" "copilot" "--version"

# ---------- 2. azd extensions ----------
section "2. Foundry azd extensions"

REQUIRED_EXTS=("azure.ai.agents" "azure.ai.projects" "azure.ai.inspector")

if ! command -v azd >/dev/null 2>&1; then
    fail "azd missing; skipping extension checks"
else
    EXT_LIST=$(azd extension list --installed 2>/dev/null || true)
    for ext in "${REQUIRED_EXTS[@]}"; do
        line=$(echo "$EXT_LIST" | awk -v id="$ext" '$1==id {print}')
        if [[ -z "$line" ]]; then
            fail "$ext not installed"
            if ask_yes "install $ext now?"; then
                if azd extension install "$ext" >/dev/null; then
                    pass "installed $ext"
                    FAILED=$((FAILED-1))
                else
                    detail "azd extension install $ext failed; run manually"
                fi
            fi
            continue
        fi
        status=$(echo "$line" | awk '{print $(NF-2)" "$(NF-1)}' | tr -s ' ')
        if echo "$line" | grep -qi "Up to date"; then
            pass "$ext up to date"
        else
            warn "$ext has an update available"
            detail "$line"
            if ask_yes "upgrade $ext now?"; then
                if azd extension upgrade "$ext" >/dev/null; then
                    pass "upgraded $ext"
                    WARNED=$((WARNED-1))
                else
                    detail "azd extension upgrade $ext failed; run manually"
                fi
            fi
        fi
    done
fi

# ---------- 3. auth ----------
section "3. Authentication"

# az
if ! command -v az >/dev/null 2>&1; then
    fail "az missing; skipping az auth check"
else
    if az account show >/dev/null 2>&1; then
        sub=$(az account show --query "name" -o tsv 2>/dev/null || echo "?")
        pass "az signed in"
        detail "subscription: $sub"
    else
        fail "az not signed in"
        if ask_yes "run 'az login' now?"; then
            if az login; then
                pass "az login complete"
                FAILED=$((FAILED-1))
            else
                detail "az login failed; run manually"
            fi
        fi
    fi
fi

# azd
if ! command -v azd >/dev/null 2>&1; then
    fail "azd missing; skipping azd auth check"
else
    azd_status=$(azd auth status 2>/dev/null || true)
    if echo "$azd_status" | grep -qi "not logged in"; then
        fail "azd not signed in"
        if ask_yes "run 'azd auth login' now?"; then
            if azd auth login; then
                pass "azd login complete"
                FAILED=$((FAILED-1))
            else
                detail "azd auth login failed; run manually"
            fi
        fi
    else
        pass "azd signed in"
    fi
fi

# ---------- 4. workspace state ----------
section "4. Workspace state"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

if [[ -d "$REPO_ROOT/.azure" ]]; then
    warn ".azure/ folder already exists"
    detail "$REPO_ROOT/.azure"
    detail "an earlier azd env is present; consider 'azd env list' before you create a new one"
else
    pass "no prior .azure/ folder"
fi

if [[ -f "$REPO_ROOT/.env" ]]; then
    warn ".env file already exists at repo root"
    detail "$REPO_ROOT/.env"
    detail "review it before continuing; secrets may be stale"
else
    pass "no prior .env file"
fi

# ---------- summary ----------
printf "\n%s==>%s %sSummary%s\n" "$BLUE" "$RESET" "$BOLD" "$RESET"
if (( FAILED == 0 && WARNED == 0 )); then
    printf "  %s✓%s ready. next: ./labs/_devguide/01-provision.sh\n" "$GREEN" "$RESET"
    exit 0
elif (( FAILED == 0 )); then
    printf "  %s!%s ready to provision with warnings above.\n" "$YELLOW" "$RESET"
    exit 0
else
    printf "  %s✗%s %d check(s) failed. address them, then re-run this script.\n" "$RED" "$RESET" "$FAILED"
    exit 1
fi
