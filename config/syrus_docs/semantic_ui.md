# Semantic UI (DOC-27)

DOC-27 ("Semantic Design Element Library and Themable Frontend Styling")
built a shared set of React primitives — `Page`, `Section`, `Surface`,
`Text`, `DataTable`, `DescriptionList`, `Form`, `Notice`, `CodeSurface`,
`Metric`, `Timeline`, `Pill`/`Badge`, layout helpers, and more — so routine
Syrus UI expresses intent ("this is a page", "this is a muted caption")
instead of restating a pile of raw Tailwind utility classes on every DOM
node. This doc is the status/reference page for that effort: where the
primitives live, what conventions apply, how much of the frontend has
migrated, how the enforcement ratchet works, and what plugins are expected
to do. It complements, rather than replaces, three more detailed docs:

- `app/frontend/components/ui/README.md` — the full per-component contract
  table and import examples. Read that first for "what does `Surface`
  actually support."
- `config/syrus_docs/design_system_eslint_ratchet.md` — the enforced
  ESLint rules, baseline mechanics, and how to add a local exception.
- `config/syrus_docs/style_debt_report.md` — the report-only script that
  tracks migration hot spots not yet promoted into the enforced ratchet.

## Import path and conventions

New app and plugin code imports primitives from the one stable barrel:

```tsx
import { Page, Section, Surface, Text, DataTable, Notice, Button } from "@app/components/ui"
```

`@app/components/ui` re-exports both the newer DOC-27 primitives (`Page`,
`Section`, `Surface`, `Text`, `DataTable`, `DescriptionList`, `Form`,
`Notice`, `CodeSurface`, `Metric`, `Timeline`, `Pill`/`Badge`, `LinkText`,
`ToolCard`, layout helpers) and the pre-existing shared components
(`Button`, `Input`, `Select`, `Textarea`, `Checkbox`, `Toggle`, `Modal`,
`Card`, `StatusPill`/`TonePill`, `PanelMessage`, `PageHeading`/
`SectionHeading`) it was built alongside. Callers should not need to know
or care which "generation" a given export belongs to — that is exactly what
the stable barrel is for. See the README above for the full contract table.

Primitives are boring React passthroughs: they accept `className`, `id`,
`aria-*`, `data-*`, and event handlers, and compose with plain JSX rather
than a templating DSL. A migrated page shell looks like:

```tsx
<Page.Root size="wide">
  <Page.Header>
    <Page.Title>Dashboard</Page.Title>
    <Page.Actions><Button tone="primary">New Job</Button></Page.Actions>
  </Page.Header>
  <Section.Root divided>
    <Section.Header><Section.Title>Work attempts</Section.Title></Section.Header>
    <Section.Body padding="sm"><Text muted>No attempts yet.</Text></Section.Body>
  </Section.Root>
</Page.Root>
```

Primitives consume CSS custom properties (`--color-*`, `--radius-*`,
`--space-*`, `--shadow-*`, `--font-*`, etc.) rather than hardcoding Tailwind
color/shape/spacing utilities directly, which is what makes them themable —
see "Theming beyond color" below. `/design_system` (and, when the
`syrus_dev` plugin is enabled, `/admin/design_system`) renders a live
gallery of every primitive against the active theme's real token values;
it is the fastest way to see what a primitive looks like without wiring up
a page.

## Migration status

DOC-27 shipped in slices (foundation primitives → tables/description lists
→ forms → job/workflow/timeline surfaces → plugin adoption → theme
expansion → enforcement/cleanup) rather than one rewrite. As of this
validation pass:

- Representative core surfaces migrated: dashboard, job detail, epic
  detail, admin queue/stuck/processes/plugins, repository settings and
  forms, chat tool cards, the diff-review workspace, and the operational
  diagnostics screens (worker health, target graph, agent activity).
- First-party plugins migrated to shared primitives for their route shells
  and tool cards (`scheduled_tasks`, `design_docs`, `build_cache`,
  `test_insights`, `git_history`, `agent_activity`, `mysql_db_browser`,
  `theming_tools`, `k8s_cluster`, and others).
- The enforced ESLint ratchet (see below) blocks *new* raw form elements,
  hand-rolled button classes, raw gray/status colors, repeated panel
  shells, raw table markup, and long class strings everywhere in
  `app/frontend` and `plugins/*/app/frontend`; a seventh rule blocks new
  legacy `blue-*`/`terracotta-*` tokens, scoped to the `lib`, `routes`, and
  `components` subdirectories (and their plugin equivalents) rather than
  every file.
- Remaining, tracked-but-not-yet-enforced debt: `bin/style-debt-report`'s
  one still-open category, `plugin-ui-imports` (a plugin file rendering 8+
  JSX elements with no `@app/components/ui` import), currently flags 30
  occurrences across 30 files — mostly MySQL browser and metrics-dashboard
  plugin surfaces with dense, domain-specific tables/charts. Run
  `bin/style-debt-report` for the current count and file list.
- Remaining, intentionally grandfathered debt: the ratchet's checked-in
  baseline (`eslint-rules/baseline.json`) still records pre-existing
  low-level styling that predates each rule — largest by far is
  `no-raw-status-colors` (about 10,000 occurrences across ~280 files, i.e.
  a raw `text-gray-*`/`bg-red-*`/etc. utility that existed before the rule
  started enforcing). The ratchet's job is to stop that number from
  growing, not to retroactively rewrite it in one pass; it shrinks only
  when a later migration job touches one of those files and regenerates
  the baseline (`bin/generate-eslint-baseline`) to capture the smaller
  count.
- Obsolete migration-bridge helpers are retired once their call sites move
  off them (most recently: local UI helpers superseded by the primitives
  above). A helper that still has real callers stays — see
  `app/frontend/components/ui/README.md`'s "DOC-27 migration target" column
  for which pre-existing components are permanent (e.g. `Button`, `Modal`,
  `Card`) versus migration bridges expected to be retired later (e.g.
  `PanelMessage` → `Notice`, `PageHeading`/`SectionHeading` → `Page.Title`/
  `Section.Title`).

This is deliberately not "100% migrated." DOC-27's own Definition of Done
is about routine UI being buildable from primitives and new debt being
practically nudged away, not about zero raw Tailwind anywhere — see
"Definition of Done" below.

## Exceptions policy

The enforced ratchet (`eslint-rules/`, wired into `eslint.config.js` and the
`frontend-lint` grader) allows exceptions through two mechanisms, matching
how much of a file is affected:

- **One-off, with a reason** — a standard ESLint disable comment:
  `{/* eslint-disable-next-line design-system/no-raw-status-colors -- reason */}`.
- **Whole file, with a reason** — add the file to the relevant rule's own
  exemption list, or to the shared `DOCUMENTED_EXCEPTIONS`/
  `DESIGN_SYSTEM_BASENAMES` list in `eslint-rules/rule-utils.js`, with a
  short comment explaining why (e.g. a color-picker file where a raw color
  utility is a literal choice offered to the user, not a styling decision).

A baseline bump is **not** an exception mechanism — the baseline tracks
debt that already existed when a rule started enforcing, not new usage. New
intentional usage always gets a disable comment or an exemption-list entry,
so the reasoning is visible in the diff. See
`config/syrus_docs/design_system_eslint_ratchet.md` for the full rule table
and how to extend the ratchet with a new rule.

## Plugin expectations

Plugin frontend code is expected to start from the same
`@app/components/ui` surface core uses — page shells, surfaces, headings,
forms, tables, notices, tool-result cards, and code/log surfaces should all
come from the shared primitives rather than a plugin-local copy of
`rounded border bg-white dark:bg-gray-900`, a hand-rolled button class
string, or a bespoke table header style. Plugin-specific visuals (an icon,
a logo, a domain-specific chart or graph, a specialized status
visualization) remain plugin-owned and render *inside* those shared
surfaces. `rails generate syrus:plugin NAME --frontend` scaffolds a small
admin-page example that already imports from `@app/components/ui`. The
enforced ratchet applies to `plugins/*/app/frontend` the same as core, and
the not-yet-enforced `plugin-ui-imports` report (above) is specifically
aimed at catching plugin pages that render substantial UI without touching
the shared primitives at all. See
`config/syrus_docs/plugins.md`'s "Frontend UI primitives" section for the
full guidance plugin authors see.

## Theming beyond color

Themes are not limited to color. `Theme` token groups include shape
(`radius-control`, `radius-panel`, `radius-pill`, `border-width`), shadow
(`shadow-panel`), spacing/density (`space-page-x`, `space-section`,
`control-height-*`, `table-row-height`), and typography (`font-sans`,
`font-mono`, `text-page-title`, etc.) alongside the semantic color tokens
(`color-surface`, `color-text-muted`, `color-border`, and so on). The
built-in `console` theme is the proof that this actually works end to end:
it swaps in sharp corners, no panel shadow, a tighter control/spacing
rhythm, and an all-monospace type stack, and every semantic primitive
(`Page`, `Section`, `Surface`, `DataTable`, `Notice`, `Button`, `Pill`,
etc.) picks that up globally with no call-site changes — verified during
this validation pass across the dashboard, job detail, admin queue, and the
`/design_system` gallery itself, in both light and dark mode. See
`db/seeds/themes.rb` for the full token set per built-in theme and
`website/src/content/docs/features.md`'s "Color theme" entry for the
user-facing description (already documents `console` and the design-system
gallery; no update needed there for this pass).

## Testing this layer

- `npm run typecheck`, `npm run lint`, and `bin/test-react` (typecheck +
  Vitest) are the fast local/CI signal; `bin/style-debt-report` reports the
  not-yet-enforced migration categories without failing anything.
- `e2e/operational-surfaces-visual.spec.ts` exercises representative
  surfaces (job detail, workflow diagnostics, a chat tool card) in both
  light and dark theme via Playwright, asserting no horizontal overflow and
  a theme-appropriate background.
- The `visual_review` workflow step (gated on `app/frontend`/`app/views`
  diffs, see `config/syrus_docs/visual_review.md`) drives a real headless
  browser against a live preview for UI-affecting PRs.
- As part of this doc's own validation pass, a manual visual sweep covered
  the dashboard, job list/detail (including the diff-review workspace),
  admin queue, `/design_system` gallery, Design Docs, and Agent Activity in
  light, dark, and the `console` alternate theme, confirming primitives
  render correctly and pick up non-color token changes globally.
- Known gap: at the time of this pass, several pre-existing Playwright E2E
  specs (`e2e/job-lifecycle.spec.ts`, `e2e/admin-panel.spec.ts`,
  `e2e/dashboard.spec.ts`, and `e2e/operational-surfaces-visual.spec.ts`
  itself) fail for reasons unrelated to DOC-27 — a Job Detail header
  reorganization moved an action behind an overflow menu, a reconciler
  classification label changed, an e2e fixture leaks a `SolidQueue::Process`
  row with no teardown, and several routes render a `<main>` landmark
  nested inside `AppChromeV2`'s own `<main>` (a pattern that predates
  DOC-27). These were flagged separately rather than fixed here, since
  they are out of this job's scope and none of them are DOC-27 regressions.

## Definition of Done

DOC-27's Definition of Done is: most routine Syrus UI can be built from
semantic primitives, product call sites no longer repeat low-level visual
class strings for common surfaces, and themes can change color, shape,
density, and typography through tokens rather than page rewrites.
Concretely, as validated by this pass:

- **Primitives exist and are documented** for pages, sections, surfaces,
  text, layout, tables, description lists, forms, notices, code surfaces,
  metrics, timelines, pills/badges, and tool cards
  (`app/frontend/components/ui/README.md`).
- **Representative core and plugin surfaces are migrated** (see "Migration
  status" above); new code is nudged toward primitives by the enforced
  ratchet rather than by convention alone.
- **Themes already change more than color** — the `console` built-in theme
  demonstrates shape, shadow, density, and typography variation applied
  globally through the same primitives, with no call-site changes.
- **The ratchet prevents regression** — `frontend-lint` (wired into
  review/landing/CI) fails on any new violation beyond each file's
  checked-in baseline, across seven enforced rules.

Remaining low-level styling is either grandfathered pre-existing debt
tracked by the baseline (shrinking as later migrations touch those files)
or inside the design system's own implementation, which is exactly where
DOC-27 always expected Tailwind to still live as an implementation detail.
