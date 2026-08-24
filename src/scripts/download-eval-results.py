"""Download per-item eval run results and cluster failures by rubric dimension.

Configure via environment variables (all required — script exits if any is missing):
    AZURE_AI_PROJECT_ENDPOINT   Full project endpoint URL
    FOUNDRY_EVAL_ID             The eval catalog ID
    FOUNDRY_RUN_ID              The eval run ID to download
    FOUNDRY_EVALUATOR_NAME      The rubric evaluator name
    FOUNDRY_RG_NAME             The resource group / env name (used only in output path)
"""
import json, os, pathlib, sys
from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient

_REQUIRED = ["AZURE_AI_PROJECT_ENDPOINT", "FOUNDRY_EVAL_ID", "FOUNDRY_RUN_ID",
             "FOUNDRY_EVALUATOR_NAME", "FOUNDRY_RG_NAME"]
_missing = [k for k in _REQUIRED if not os.environ.get(k)]
if _missing:
    sys.exit(f"Missing required env vars: {', '.join(_missing)}")

PROJECT_ENDPOINT = os.environ["AZURE_AI_PROJECT_ENDPOINT"]
EVAL_ID    = os.environ["FOUNDRY_EVAL_ID"]
RUN_ID     = os.environ["FOUNDRY_RUN_ID"]
EVALUATOR  = os.environ["FOUNDRY_EVALUATOR_NAME"]
OUT_DIR    = pathlib.Path(__file__).parent.parent / ".foundry" / "results" / os.environ["FOUNDRY_RG_NAME"] / EVAL_ID

OUT_DIR.mkdir(parents=True, exist_ok=True)
OUT_FILE = OUT_DIR / f"{RUN_ID}.json"

client = AIProjectClient(endpoint=PROJECT_ENDPOINT, credential=DefaultAzureCredential())
oai = client.get_openai_client()

output_items = list(oai.evals.runs.output_items.list(run_id=RUN_ID, eval_id=EVAL_ID))
all_items = [item.model_dump() for item in output_items]
OUT_FILE.write_text(json.dumps(all_items, indent=2))
print(f"Saved {len(all_items)} items → {OUT_FILE}")

# Merge dual entries and report per-item
DIMS = ["task_and_scope_classification","required_slot_collection",
        "retrieval_target_and_query_alignment","grounded_reporting_accuracy",
        "no_result_and_unsupported_handling","actionable_response_presentation","general_quality"]

rows = []
for item in all_items:
    ds = item.get("datasource_item", {})
    query = ds.get("query", ds.get("input", ""))
    score_val, passed_val, reason_val = None, None, None
    for r in item.get("results", []):
        m = r.get("metric", "")
        if m == "custom_score":
            score_val = r.get("score")
        elif m == EVALUATOR:
            passed_val = r.get("passed")
            reason_val = r.get("reason", "")
    rows.append({"query": query, "score": score_val, "passed": passed_val, "reason": reason_val})

print(f"\n{'#':>2}  {'Pass':4}  {'Score':5}  Query (truncated)")
print("-" * 70)
for i, r in enumerate(rows, 1):
    p = "PASS" if r["passed"] else "FAIL"
    s = f"{r['score']:.2f}" if r["score"] is not None else "  -- "
    print(f"{i:>2}  {p:4}  {s:5}  {str(r['query'])[:56]}")

failures = [r for r in rows if not r["passed"]]
print(f"\n=== FAILURES ({len(failures)}/{len(rows)}) ===")
for r in failures:
    print(f"\nQ: {r['query']}")
    print(f"   Reason: {r['reason'][:300]}")
