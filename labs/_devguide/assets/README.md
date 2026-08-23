# Coaches Guide — screenshot assets

Drop new screenshots here as-is (any name — for example `Screenshot 2026-08-23 at 12.14.png`). The guide author will rename them to match the guide's numbering.

## Naming convention

```
<chapter>-<section>[-<subsection>]-<short-descriptor>.png
```

Rules:

- Use the guide's numbering as the prefix so files sort in the order we meet them (§6.1 → `6-1-...`, §6.2 → `6-2-...`).
- Replace `.` with `-` so the filename stays shell-friendly.
- Keep the descriptor to one or two lowercase words joined with `-` (context cue only — the guide caption carries the full meaning).
- Lowercase everything, no spaces.
- Prefer `.png`. If a source is `.jpg` or `.webp`, keep the original extension.
- If a step needs multiple shots, add a two-digit suffix: `-01`, `-02`.

## Examples

| Section | File |
|---|---|
| §6.1 quickstart run | `6-1-quickstart-summary.png` |
| §6.1 tool versions | `6-1-tool-versions.png` |
| §6.2 az device code login | `6-2-az-login-01.png` |
| §6.2 azd status after login | `6-2-azd-status.png` |
| §6.5 Foundry portal landing | `6-5-portal-landing.png` |

## Where they appear

Reference from [COACHES.md](../COACHES.md) using relative paths, for example:

```markdown
![Quickstart summary](assets/6-1-quickstart-summary.png)
```

## Notes

- Redact any subscription IDs, tenant IDs, resource tokens, or PII before dropping the file. If a shot contains sensitive detail you can't blur, leave a note in the same commit and we'll capture a clean version together.
- Keep image size reasonable (roughly under 500 KB). If a screenshot is much larger, prefer PNG optimization or a JPEG.
