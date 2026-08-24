#!/usr/bin/env bash
# generate-traffic.sh — replay Contoso Travel Concierge sample prompts
# against the deployed agent to populate traces and Monitor charts.
#
# Reads artifacts/datasets/reference/sample-prompts-v1.jsonl and prints
# (or sends) each row's `query` field. Supports category / outcome filters
# and repeat counts for building meaningful traffic volume.
#
# What it does:
#   1. Resolves the target azd env (most-recent contoso-travel-* or $AZD_ENV_NAME).
#   2. Loads sample-prompts-v1.jsonl.
#   3. Filters by --category and/or --outcome.
#   4. Either PRINTS queries (default; copy-pasteable) or SENDS them
#      via `azd ai agent invoke` (--send).
#
# What it does NOT do:
#   - Retry on failure. Each turn is best-effort.
#   - Multi-turn conversations. All rows are single-turn (v1).
#   - Load-test at scale. Use `--repeat` for modest volume; for real
#     load testing use a proper tool.
#
# Env vars:
#   AZD_ENV_NAME   Explicit azd env name.
#   AGENT_NAME     Target agent (default: contoso-travel-concierge-prompt).
#   SEED_FILE      Path to seed JSONL (default: artifacts/datasets/reference/sample-prompts-v1.jsonl).
#
# Flags:
#   --category <c>   Filter by tags.category (flight|hotel|car|multi|clarification|
#                    out_of_scope|adversarial|edge|ambiguous). Repeat for OR.
#   --outcome <o>    Filter by tags.expected_outcome (grounded_answer|clarification|
#                    refusal|no_match|boundary_check). Repeat for OR.
#   --limit <N>      Stop after N filtered rows (default: all).
#   --repeat <N>     Replay the (filtered) set N times (default: 1).
#   --send           Actually invoke the deployed agent (default: print only).
#   --sleep <s>      Seconds to sleep between --send invocations (default: 1).
#   --numbered       Print queries with row numbers.
#   --quiet          Suppress the intro/summary banner.
#   --help           Print this header.
#
# Exit codes:
#   0  Ran to completion (or printed everything).
#   1  A prerequisite failed.
#   2  Bad flag.

set -uo pipefail

# ---------- flags ----------
CATEGORY_FILTERS=()
OUTCOME_FILTERS=()
LIMIT=0
REPEAT=1
SEND=0
SLEEP_S=1
NUMBERED=0
QUIET=0
while (( $# )); do
    case "$1" in
        --category)  CATEGORY_FILTERS+=("$2"); shift 2 ;;
        --outcome)   OUTCOME_FILTERS+=("$2"); shift 2 ;;
        --limit)     LIMIT=$2; shift 2 ;;
        --repeat)    REPEAT=$2; shift 2 ;;
        --send)      SEND=1; shift ;;
        --sleep)     SLEEP_S=$2; shift 2 ;;
        --numbered)  NUMBERED=1; shift ;;
        --quiet|-q)  QUIET=1; shift ;;
        --help|-h)   grep '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done

# ---------- output helpers ----------
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BLUE=$'\033[34m'
else
    BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""; RED=""; BLUE=""
fi

banner() { (( QUIET )) && return; printf "\n%s==>%s %s%s%s\n" "$BLUE" "$RESET" "$BOLD" "$1" "$RESET"; }
info()   { (( QUIET )) && return; printf "    %s%s%s\n" "$DIM" "$1" "$RESET"; }
ok()     { (( QUIET )) && return; printf "  %s✓%s %s\n" "$GREEN" "$RESET" "$1"; }
warn()   { printf "  %s!%s %s\n" "$YELLOW" "$RESET" "$1"; }
fail()   { printf "  %s✗%s %s\n" "$RED" "$RESET" "$1"; }

# ---------- context ----------
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SEED_FILE="${SEED_FILE:-$REPO_ROOT/artifacts/datasets/reference/sample-prompts-v1.jsonl}"
AGENT_NAME="${AGENT_NAME:-contoso-travel-concierge-prompt}"

# Resolve azd env (only needed when --send).
if (( SEND )); then
    if [[ -z "${AZD_ENV_NAME:-}" ]]; then
        if [[ -d "$REPO_ROOT/.azure" ]]; then
            AZD_ENV_NAME=$(ls -1t "$REPO_ROOT/.azure" 2>/dev/null | grep '^contoso-travel-' | head -n1 || true)
        fi
    fi
    if [[ -z "$AZD_ENV_NAME" ]]; then
        fail "no azd env found. run ./01-provision.sh first, or set AZD_ENV_NAME."
        exit 1
    fi
fi

# ---------- validate ----------
if [[ ! -f "$SEED_FILE" ]]; then
    fail "seed file not found: $SEED_FILE"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 required to parse JSONL"
    exit 1
fi

if (( SEND )) && ! command -v azd >/dev/null 2>&1; then
    fail "azd required when using --send"
    exit 1
fi

# ---------- filter ----------
# Build a filtered JSON array of {query, purpose, category, outcome}
FILTERED=$(python3 - "$SEED_FILE" "${CATEGORY_FILTERS[@]:-}" "--" "${OUTCOME_FILTERS[@]:-}" <<'PY'
import json, sys
path = sys.argv[1]
# Separator marks end of category filters and start of outcome filters.
try:
    sep = sys.argv.index("--", 2)
except ValueError:
    sep = len(sys.argv)
cats = [a for a in sys.argv[2:sep] if a]
outs = [a for a in sys.argv[sep+1:] if a]
rows = []
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        tags = r.get("tags", {})
        cat = tags.get("category", "")
        out = tags.get("expected_outcome", "")
        if cats and cat not in cats:
            continue
        if outs and out not in outs:
            continue
        rows.append({
            "query": r.get("query", ""),
            "purpose": r.get("purpose", ""),
            "category": cat,
            "outcome": out,
        })
print(json.dumps(rows))
PY
)

TOTAL=$(echo "$FILTERED" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')

if (( LIMIT > 0 && LIMIT < TOTAL )); then
    LIMIT_APPLIED=$LIMIT
else
    LIMIT_APPLIED=$TOTAL
fi

banner "Contoso Travel Concierge — traffic generator"
info "seed file:   $SEED_FILE"
info "agent:       $AGENT_NAME"
info "filters:     categories=[${CATEGORY_FILTERS[*]:-all}] outcomes=[${OUTCOME_FILTERS[*]:-all}]"
info "rows:        $TOTAL matched, $LIMIT_APPLIED will run × $REPEAT repeat = $((LIMIT_APPLIED * REPEAT)) total turns"
if (( SEND )); then
    info "mode:        SEND (via azd ai agent invoke on env '$AZD_ENV_NAME')"
else
    info "mode:        PRINT only (use --send to invoke the deployed agent)"
fi

if (( TOTAL == 0 )); then
    warn "no rows matched the filters. adjust --category / --outcome and re-run."
    exit 0
fi

# ---------- execute ----------
COUNT=0
for (( iter=1; iter<=REPEAT; iter++ )); do
    (( REPEAT > 1 && QUIET == 0 )) && printf "\n%s[iteration %d/%d]%s\n" "$DIM" "$iter" "$REPEAT" "$RESET"
    idx=0
    while IFS= read -r row; do
        idx=$((idx+1))
        (( LIMIT > 0 && idx > LIMIT )) && break

        query=$(echo "$row" | python3 -c 'import json,sys; print(json.load(sys.stdin)["query"])')
        cat=$(echo "$row" | python3 -c 'import json,sys; print(json.load(sys.stdin)["category"])')
        out=$(echo "$row" | python3 -c 'import json,sys; print(json.load(sys.stdin)["outcome"])')

        if (( NUMBERED )); then
            prefix=$(printf "%2d. [%s/%s]" "$idx" "$cat" "$out")
        else
            prefix="[$cat/$out]"
        fi

        if (( SEND )); then
            printf "%s%s%s %s\n" "$BOLD" "$prefix" "$RESET" "$query"
            if ! (cd "$REPO_ROOT" && azd ai agent invoke "$AGENT_NAME" \
                    --input "$query" -e "$AZD_ENV_NAME" 2>/dev/null | head -20); then
                warn "invoke failed for: $query"
            fi
            sleep "$SLEEP_S"
        else
            printf "%s%s%s %s\n" "$BOLD" "$prefix" "$RESET" "$query"
        fi
        COUNT=$((COUNT+1))
    done < <(echo "$FILTERED" | python3 -c 'import json,sys; [print(json.dumps(r)) for r in json.load(sys.stdin)]')
done

banner "Summary"
if (( SEND )); then
    ok "sent $COUNT turn(s) to $AGENT_NAME. Check Monitor / traces in the Foundry portal."
else
    ok "printed $COUNT prompt(s). Use --send to actually invoke the deployed agent."
fi
