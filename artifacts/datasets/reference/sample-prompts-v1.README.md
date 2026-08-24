# Sample Prompts (v1) — dual-purpose Concierge seed & traffic set

**File:** [`sample-prompts-v1.jsonl`](sample-prompts-v1.jsonl) · **Rows:** 25 · **Turn shape:** single-turn only

A curated set of Contoso Travel Concierge prompts covering the normal path, edge cases, out-of-scope, adversarial, and boundary tests. Two intended uses:

1. **Seeds** for dataset and evaluator generation flows (Core Lab 03 optimize skill, `more/trace-driven-datasets.md`).
2. **Traffic** for populating traces and monitoring dashboards (Core Lab 01 observe, Core Lab 04 monitor).

Because it targets both, every row is **single-turn** and stands on its own — no shared context needed. Multi-turn prompts are covered in the extension challenge below.

## Schema

Each row is a JSON object:

```json
{
  "query": "string — the traveler's prompt",
  "purpose": "string — one-line note on what this stresses",
  "tags": {
    "category": "flight | hotel | car | multi | clarification | out_of_scope | adversarial | edge | ambiguous",
    "expected_outcome": "grounded_answer | clarification | refusal | no_match | boundary_check"
  }
}
```

## Coverage summary

| Category | Count | Expected outcome | What it exercises |
|---|---|---|---|
| `flight` | 4 | `grounded_answer` | flight tool + retrieval, ranking, cabin/class filters |
| `hotel` | 4 | `grounded_answer` | hotel tool + retrieval, amenity filters, star ratings |
| `car` | 3 | `grounded_answer` | car rental tool + retrieval, class filters |
| `multi` | 3 | `grounded_answer` | cross-dataset composition, multi-city itineraries |
| `clarification` | 2 | `clarification` | seed prompt's "ask for missing details" clause — surfaces the v3 baseline weakness |
| `out_of_scope` | 3 | `refusal` | non-travel questions (cooking, books, code) — tests scope refusal |
| `adversarial` | 2 | `refusal` | prompt-injection and role-override attempts — safety evaluator hits |
| `edge` | 2 | `no_match` | routes or dates outside the dataset — should acknowledge no match |
| `ambiguous` | 2 | `boundary_check` | travel-adjacent traps (weather, subjective opinions) |

## Use A — Seed prompts for dataset generation

Point Copilot at this file when running the `observe` sub-skill or the `eval-datasets` sub-skill. It gives the generator broad, well-labeled starting queries and preserves the tier / category distribution.

Example Copilot prompt:

```text
Using the microsoft-foundry observe sub-skill, generate an evaluation suite
for contoso-travel-concierge-prompt. Seed the generation with the queries in
artifacts/datasets/reference/sample-prompts-v1.jsonl. Preserve the tag
distribution and add per-row expected_behavior fields.
```

To stage this file into `artifacts/datasets/generated/` for a run:

```bash
./scripts/use-reference.sh datasets sample-prompts-v1
```

## Use B — Load-test traffic for observability

Fire these 25 prompts against the deployed agent to populate traces and Monitor charts.

Diverse-enough coverage means:

- **Failure charts get color** — clarification, out_of_scope, and edge rows produce non-happy-path traces.
- **Safety evaluator scores something real** — the two adversarial rows trigger indirect-attack detection.
- **Retrieval health is visible** — multi-part rows stress the top-K retriever, boundary rows probe the scope guard.

Use the runner:

```bash
./labs/_devguide/generate-traffic.sh                          # print all 25 for copy-paste
./labs/_devguide/generate-traffic.sh --category flight        # only flight prompts
./labs/_devguide/generate-traffic.sh --outcome refusal        # only prompts we expect to be refused
./labs/_devguide/generate-traffic.sh --send                   # actually invoke against the deployed agent
./labs/_devguide/generate-traffic.sh --send --repeat 3        # 3× volume for visible Monitor charts
```

See the script's `--help` for the full flag list.

## Category glossary

- **flight / hotel / car** — single-specialist grounded queries. Should return one or more IDs (CT-FL-*, CT-HT-*, CT-CR-*) with the correct filter applied.
- **multi** — spans two or more datasets. Tests cross-dataset composition in a single response.
- **clarification** — under-specified. The seed prompt has an explicit "before answering, make sure you have everything you need" clause. Baseline v3 over-asks here; that's the failure mode we optimize away in Core Lab 03.
- **out_of_scope** — not travel-related. The seed prompt has an explicit "Out of scope" clause. Should decline politely.
- **adversarial** — attempts to jailbreak or override role. Should refuse to reveal internal instructions or comply with the injection.
- **edge** — legitimately travel-shaped queries where the answer simply is not in the dataset. Tests whether the agent invents plausible fictions vs. acknowledges no match.
- **ambiguous** — travel-adjacent traps or subjective questions. Tests whether the agent stays factual and in scope even when the boundary is fuzzy.

## Extension challenge — build a multi-turn seed set

This v1 file is single-turn only, which keeps the schema simple and the traffic script deterministic. Multi-turn conversation traces are a richer signal — they surface behaviors like "the agent forgets what the traveler asked in turn 1" — but they need a different shape.

**Try this end-to-end challenge** once you have Core Labs 01–04 working:

1. Ask Copilot to draft a `sample-prompts-v2-multiturn.jsonl` from this v1 file, adding a `conversation` field with 2–3 turns per row that stress the same categories.
2. Use the `eval-datasets` sub-skill to convert your multi-turn seeds into a versioned evaluation dataset with per-row `expected_behavior`.
3. Add a `--multi-turn` mode to `generate-traffic.sh` that fires each conversation as a sequence, preserving thread state.
4. Compare Monitor charts before and after: does the multi-turn set surface failure patterns the single-turn set missed?

Suggested Copilot prompts, in order:

```text
Draft artifacts/datasets/reference/sample-prompts-v2-multiturn.jsonl.
Use sample-prompts-v1.jsonl as the shape base, but add a conversation array
per row with 2-3 turns each. Keep the same categories and expected outcomes.
The multi-turn shape should stress cross-turn memory: a clarification turn
followed by a follow-up that references what the traveler said earlier.
```

```text
Using the microsoft-foundry eval-datasets sub-skill, convert
sample-prompts-v2-multiturn.jsonl into a versioned evaluation dataset with
per-row expected_behavior fields. Register it as a new evaluation suite
against contoso-travel-concierge-prompt.
```

This is intentionally set up as a solo exercise so learners get real practice with the sub-skills before moving on to the Capstone.

## Not intended for

- Evaluation scoring with rubric criteria. Use [`evaluation-data-v2.jsonl`](evaluation-data-v2.jsonl) — it has `expected_behavior` on every row.
- Ground-truth-based comparisons. This file omits `ground_truth` on purpose; the load-test story doesn't need it and the seed-generation story shouldn't inherit it.
- Automated CI regression gates. Use [`evaluation-data-v1.jsonl`](evaluation-data-v1.jsonl) for a fast, 10-row smoke suite.
