# DOC-27 Style-Debt Report

`bin/style-debt-report` measures how much of the frontend still relies on raw,
low-level Tailwind class strings instead of the semantic design-system
primitives under `app/frontend/components/ui` (DOC-27, "Semantic Design
Element Library and Themable Frontend Styling"). It is report-only: it never
fails the process it runs in, and it is separate from the enforced ratchet
described below.

## Relationship to the enforced ratchet

`eslint-rules/` enforces a set of ratchet rules against a per-file baseline
in `eslint-rules/baseline.json` — new violations beyond that baseline fail
`npx eslint`, and (via the `frontend-lint` grader in `.syrus.yml`) fail the
Syrus review/landing/CI grade. This script measures a broader,
not-yet-enforced set of migration hot spots so future jobs can see where to
migrate next and, eventually, decide which remaining categories are ready to
graduate into the enforced ratchet.

Four categories already graduated this way: `raw-status-colors`,
`panel-shell-repeats`, `raw-table-classes`, and `long-class-strings` used to
live here and now run as the enforced `no-raw-status-colors`,
`no-panel-shell-repeats`, `no-raw-table-classes`, and `no-long-class-strings`
rules under `eslint-rules/` — see
`config/syrus_docs/design_system_eslint_ratchet.md` for the full enforced
rule set, its baseline mechanics, and how to add a local exception. They were
removed from this report so the same debt isn't counted twice. Until a
remaining category graduates the same way, this script only reports it; it
does not fail CI or block landing on its own account.

## Categories

Each category is a report-only ESLint rule under `eslint-rules/style_debt/`,
run via a dedicated ESLint instance inside `eslint-rules/style_debt/report.js`
(not wired into `eslint.config.js`, so it never affects `npx eslint`'s exit
code):

| Category | Rule key | What it flags |
|---|---|---|
| Plugin UI without `@app/components` imports | `plugin-ui-imports` | A plugin frontend file (`plugins/*/app/frontend/**`) rendering 8+ JSX elements with no import from `@app/components/*`. |

## Exclusions

Every rule skips, uniformly (`eslint-rules/style_debt/shared.js`, sourced
from `eslint-rules/rule-utils.js` so the enforced ratchet rules use the exact
same exclusion set):

- Test files (`*.test.tsx`/`*.test.ts`).
- Generated files (`*.generated.*`, `__generated__/`).
- The design system's own implementation: `app/frontend/components/ui/**`
  and the primitive leaf components living alongside it (`Button.tsx`,
  `Card.tsx`, `Input.tsx`, `Select.tsx`, `Modal.tsx`, `Checkbox.tsx`,
  `Toggle.tsx`, `Textarea.tsx`, `Heading.tsx`, `PanelMessage.tsx`,
  `StatusPill.tsx`).
- A small documented exception list: files that render user-facing color
  *pickers*, where a raw color utility is a literal choice offered to the
  user rather than a styling decision (`ImageAnnotationModal.tsx`,
  `syntaxHighlight.tsx`, `Tags.tsx`) — the same files the enforced
  `no-legacy-color-tokens` rule already exempts.

## Running it

```
bin/style-debt-report                 # human-readable report + baseline diff
bin/style-debt-report --json          # machine-readable report on stdout
bin/style-debt-report --top 30        # show more files per category (default 15)
bin/style-debt-report --write-baseline  # recompute eslint-rules/style_debt/baseline.json
```

The human-readable report lists, per category, the total count, the number
of files involved, and up to `--top` offending files sorted by count
(descending) — enough to spot migration hot spots without scrolling through
every match. `--json` returns the same data unabbreviated for CI tooling or
scripting.

## Baseline behavior

`eslint-rules/style_debt/baseline.json` is a checked-in snapshot (per
category, per file, plus a `generated_at` timestamp) produced by
`--write-baseline`. It exists purely so a future job can answer "did this
change make things better or worse": running the report without
`--write-baseline` diffs the current totals against that snapshot and prints
a `[+N vs baseline]` / `[-N vs baseline]` delta per category. It is not a
ratchet input — nothing reads it to gate a check — regenerate it (re-run
`--write-baseline` and commit the result) whenever a migration job
intentionally shrinks a category, the same way `bin/generate-eslint-baseline`
is re-run after a migration job shrinks an enforced-rule baseline.

## Extending it

To add a category, add a rule module under `eslint-rules/style_debt/`
following the existing rule's shape (a report-only ESLint rule using
`shared.isExcluded` for the standard exclusions), register it in
`eslint-rules/style_debt/index.js`'s `RULES` array, and add
`eslint-rules/style_debt/<name>.test.js` using the `lintWithRule` helper in
`eslint-rules/style_debt/test-helpers.js`. No changes to `bin/style-debt-report`
or `report.js` are needed — both iterate `RULES`.

To graduate a category into the enforced ratchet instead (once its remaining
count is low enough, or its pattern specific enough, to block new occurrences
without false-positiving on legitimate layout), move its matching logic into
a new `no-<name>.js` rule under `eslint-rules/` following
`no-raw-status-colors.js`'s shape (baseline-aware via
`rule-utils.reportBeyondBaseline`), register it in `eslint-rules/index.js`
and `eslint.config.js`, remove the old entry from this directory's `RULES`
array and delete its files, then run `bin/generate-eslint-baseline` to
capture the current count as the new rule's starting baseline. See
`config/syrus_docs/design_system_eslint_ratchet.md`.
