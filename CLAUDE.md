# open_oura — repo guide for agents

Independent, cloud-free client for the Oura ring: BLE sync + decode in Rust, the daily
health computations in Rust. This repository has no models. See `README.md` and
`docs/` for the details.

## ⚠️ Two clients render the same data — keep them in sync

There are **two user-facing apps** and a change usually belongs in **both**:

- **Web dashboard** — `dashboard/web/` (vanilla JS) served by `crates/oura-cli/src/dashboard.rs`.
- **Native iOS app** — `apps/ios/OuraApp/` (SwiftUI) on `crates/oura-core` (UniFFI).

Both render the JSON from the **single shared brain `crates/oura-summary` (`build_summary`)**.

Before you finish a feature, check it against **`docs/clients-web-and-ios.md`** (the
feature ↔ feature map) and apply it where it belongs:

- **New computed metric/field** → add once in `oura-summary`; render in **both** `app.js`
  **and** `OuraApp.swift`.
- **New visualization/UI** → do it in **both** `app.js` **and** `OuraApp.swift`.
- **Model results** → the app runs without models. An add-on can supply model results
  through `OURA_MODEL_RUNNER` (CLI, see `ExternalRunner` in `dashboard.rs`) or a
  `SummaryPlugin` (iOS, `SummaryPlugin.swift`). Do not add model code here.

If you intentionally do only one client, say so and note it in the "Known gaps" section of
`docs/clients-web-and-ios.md`.

## Building / running

- Web dashboard: `oura dashboard` (see `dashboard/README.md`).
- iOS (simulator): `apps/ios/OuraApp/build_run.sh`. TestFlight: `apps/ios/TESTFLIGHT.md`.
- Model files, `oura.db`, and auth keys are gitignored. Never commit them.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **open_health** (4441 symbols, 9733 relationships, 374 execution flows).

> Index stale? Run `node .gitnexus/run.cjs analyze --index-only` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? Bootstrap with `npx`, `bunx`, or `pnpm dlx` — e.g. `bunx gitnexus@latest analyze` (npm 11 npx crash; #1939).

## Always Do

- **MUST run impact analysis before editing.** Use `impact({target: "symbolName", direction: "upstream"})` (MCP) or `node .gitnexus/run.cjs impact "symbolName" --direction upstream --repo .` (CLI fallback); report callers, processes, and risk. Never substitute grep for graph analysis.
- **MUST analyze graph changes before committing.** Use `detect_changes({scope: "all"})` (MCP) or `node .gitnexus/run.cjs detect-changes --scope all --repo .` (CLI fallback). `partial: true` or `truncated: true` is not a clean check — a zero means unseen, not unaffected; re-run it. For regression review: `detect_changes({scope: "compare", base_ref: "main"})` or `node .gitnexus/run.cjs detect-changes --scope compare --base-ref "main" --repo .`.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- **MUST treat `risk: UNKNOWN` as unresolved, not as low.** An empty caller set is not evidence the symbol is unused — it can also mean the callers are not resolvable by the index (plain-object property access, dynamic dispatch, cross-language calls). `impact` pairs `UNKNOWN` with a `riskNote` saying so. Confirm with a text search before treating the symbol as safe to change or delete; do not proceed on the strength of a zero.
- When exploring unfamiliar code, use `query({search_query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `context({name: "symbolName"})`.
- For security review, `explain({target: "fileOrSymbol"})` lists taint findings (source→sink flows; needs `analyze --pdg`).

## Never Do

- NEVER edit a function, class, or method before MCP/CLI impact analysis.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis, and never read `UNKNOWN` as an all-clear — it means the walk could not answer, which is the one verdict that requires confirming by other means.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit before MCP/CLI graph change analysis.

## Resources

| Resource | Use for |
| --- | --- |
| `gitnexus://repo/open_health/context` | Codebase overview, check index freshness |
| `gitnexus://repo/open_health/clusters` | All functional areas |
| `gitnexus://repo/open_health/processes` | All execution flows |
| `gitnexus://repo/open_health/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
| --- | --- |
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
