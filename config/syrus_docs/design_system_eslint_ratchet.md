# Design-System ESLint Ratchet

`eslint-rules/` is a small local ESLint plugin (registered as `design-system`
in `eslint.config.js`) that blocks *new* raw-styling debt in `app/frontend`
and `plugins/*/app/frontend` while letting already-existing debt land
unchanged. It exists so the DOC-27 semantic-UI migration ("Semantic Design
Element Library and Themable Frontend Styling") can tighten over time without
a single big-bang cleanup PR, and so newly-written product/plugin code is
nudged toward the primitives under `app/frontend/components/ui` instead of
adding to the pile.

This is deliberately a narrow, hand-rolled rule set, not `eslint:recommended`
or a framework preset — broader linting is a separate concern.

## Enforcement

`npx eslint --no-error-on-unmatched-pattern app/frontend plugins/*/app/frontend`
(`npm run lint`) fails when any rule reports beyond its baseline. The flag
lets a plugin whose `app/frontend` holds only locale files (nothing to lint)
through instead of failing the whole run. Two things actually run it:

- The `frontend-lint` grader in `.syrus.yml` (`phases: [review, landing,
  ci]`), so a Syrus-implemented PR fails review/landing/CI the same as any
  other required grader.
- The `react` job in `.github/workflows/ci.yml`, so a PR pushed straight to
  GitHub (not through Syrus) is covered too.
- `formatters:` in `.syrus.yml` also runs `npx eslint --fix` as part of the
  normal format/autofix step, but that step never fails the workflow on its
  own (see `CLAUDE.md`'s "format"/"generate" step contract) — the
  `frontend-lint` grader is what actually blocks.

## Rules

| Rule | What it forbids | Exemptions beyond the standard set below |
|---|---|---|
| `no-raw-form-elements` | Raw `<input>`/`<select>` outside `Input`/`Select`/`Checkbox`/`Toggle`. | `Input.tsx`, `Select.tsx`, `Checkbox.tsx`, `Toggle.tsx` |
| `no-raw-button-classes` | Hand-rolled primary/secondary/danger button-look classes on raw `<button>`/`<a>`. | `Button.tsx` |
| `no-legacy-color-tokens` | New `blue-*`/`terracotta-*` Tailwind utilities in routes/components/lib. | Button/Card/Input/Select/Modal/Checkbox/Toggle leaf components; a small documented color-picker exception list |
| `no-raw-status-colors` | New raw gray/neutral (`text-gray-*`, `bg-gray-*`, `border-gray-*`, and slate/zinc/neutral/stone) and semantic-status (`red`/`amber`/`green`/etc.) Tailwind color utilities. Excludes `blue`/`terracotta`, already covered by `no-legacy-color-tokens`. | standard set only |
| `no-panel-shell-repeats` | New hand-rolled `rounded` + `border` + `bg-white`/`bg-gray-50`/`bg-gray-100` panel shells that duplicate `Surface`/`Card`. | standard set only |
| `no-raw-table-classes` | New raw `<td>`/`<th>` outside the `DataTable` primitive. | standard set only |
| `no-long-class-strings` | New JSX `className` strings over 120 characters — usually several design decisions restated on one node instead of a primitive. | standard set only |

`no-raw-status-colors`, `no-panel-shell-repeats`, `no-raw-table-classes`, and
`no-long-class-strings` graduated from report-only rules under
`eslint-rules/style_debt/` — see `config/syrus_docs/style_debt_report.md` for
the report that still tracks not-yet-enforced categories (currently just
`plugin-ui-imports`) and the process for graduating another one.

### Standard exclusion set

Every rule above skips (`eslint-rules/rule-utils.js`'s `isDesignSystemExcluded`
plus each rule's own `isTestFile`/basename check where applicable):

- Test files (`*.test.tsx`/`*.test.ts`).
- Generated files (`*.generated.*`, `__generated__/`).
- The design system's own implementation: `app/frontend/components/ui/**`
  and its leaf components (`Button.tsx`, `Card.tsx`, `Checkbox.tsx`,
  `Heading.tsx`, `Input.tsx`, `Modal.tsx`, `PanelMessage.tsx`, `Select.tsx`,
  `StatusPill.tsx`, `Textarea.tsx`, `Toggle.tsx`) — matched by basename, so a
  file named e.g. `Button.tsx` anywhere is exempt, mirroring the older
  per-rule `EXEMPT_BASENAMES` convention.
- A small documented exception list for files that render user-facing color
  *pickers*, where a raw color utility is a literal choice offered to the
  user rather than a styling decision (`ImageAnnotationModal.tsx`,
  `syntaxHighlight.tsx`, `Tags.tsx`).

## Baseline mechanics

`eslint-rules/baseline.json` records, per rule key and per file, how many
violations already existed when that rule started enforcing (or when it
graduated from `style_debt/`). Each rule's `Program:exit` handler (via
`rule-utils.reportBeyondBaseline`) collects every match in file order, then
reports only the matches beyond that file's baselined count — so a file at
its baseline stays green, and any file with no baseline entry (including
every brand-new file) has an allowance of zero.

Regenerate the baseline after a migration job shrinks a file's count (or a
new rule graduates in):

```
node bin/generate-eslint-baseline
```

This re-lints the same globs with `ESLINT_BASELINE_GENERATE=1`, which makes
every rule report *all* matches regardless of the current baseline, and
overwrites `eslint-rules/baseline.json` with the fresh counts. Commit the
regenerated file in the same PR as the change that produced the new counts.

## Adding a local exception

Two mechanisms, matching how much of a file is affected:

- **One-off, with a reason** — a standard ESLint disable comment works for
  any of these rules, since they are ordinary ESLint rules under the
  `design-system/` namespace:

  ```tsx
  {/* eslint-disable-next-line design-system/no-raw-status-colors -- intentional one-off, see PR #1234 */}
  <div className="text-gray-400">...</div>
  ```

- **Whole file, with a reason** — for a file that legitimately needs to keep
  using raw utilities for its entire lifetime (e.g. a color picker), add it
  to the rule's own exemption list (`EXEMPT_FILES`/`EXEMPT_BASENAMES` on the
  individual rule, or `DOCUMENTED_EXCEPTIONS`/`DESIGN_SYSTEM_BASENAMES` in
  `rule-utils.js` for an exception shared across every rule) with a short
  comment explaining why, following the existing entries as examples.

Do not reach for a baseline bump as an exception mechanism — the baseline
tracks pre-existing debt being paid down over time, not new, intentional
usage. A new intentional usage should get a disable comment or an exemption
list entry so its reasoning is visible in the diff, not an invisible bump to
a JSON count.

## Extending the ratchet

To add a new enforced rule, follow the shape of `no-raw-status-colors.js`:
use `rule-utils.relativePath`/`allowedCount` to look up the file's baseline
allowance, `rule-utils.isDesignSystemExcluded` (plus any rule-specific
exemptions) to skip files that aren't debt, collect matches during traversal,
and call `rule-utils.reportBeyondBaseline` from `Program:exit`. Register the
rule in `eslint-rules/index.js` and enable it for the relevant file glob in
`eslint.config.js`, then run `bin/generate-eslint-baseline` to capture the
current violation count as the rule's starting baseline before it starts
blocking new ones.
