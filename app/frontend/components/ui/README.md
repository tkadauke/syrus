# UI Component Contracts

`@app/components/ui` is the stable public import surface for shared Syrus frontend primitives. It exposes the DOC-27 semantic layer alongside compatibility exports for existing shared components so core routes and plugins can migrate without visual churn.

## Current Exports

| Component | Contract | DOC-27 migration target |
| --- | --- | --- |
| `Button` / `buttonClasses` | Native `<button>` with variants `primary`, `secondary`, `danger`, and `success`; sizes `sm`, `md`, and `icon`. Defaults to `type="button"` and keeps `buttonClasses` for links or other non-button elements that need matching styling. | Remains the command primitive; future semantic wrappers should compose it rather than duplicate button class strings. |
| `Input` | Native `<input>` with `invalid` and `fullWidth`; `fullWidth` defaults to `true`. | Remains the control primitive used by future `Form.Field` contracts. |
| `Select` | Native `<select>` with `invalid` and `fullWidth`; `fullWidth` defaults to `true`. | Remains the control primitive used by future `Form.Field` contracts. |
| `Checkbox` | Native checkbox input; optional `label` wraps the input in a label for implicit association. | Remains the boolean-control primitive. |
| `Toggle` | Native `<button role="switch">` with controlled `checked` and `onChange`; optional `label`. | Remains the switch primitive. |
| `Modal` | Portal dialog with backdrop click, Escape handling, focus trap, focus restore, accessible `label`/`labelledBy`, and overrideable panel/backdrop classes. | Remains the dialog primitive; future modal shells should compose it. |
| `Card` / `Skeleton` | Framed repeated item/preview primitives; `Card` supports `base` and `preview` variants plus `compact`. | `Card` stays for repeated cards/previews. Broader panels should migrate to future `Surface`/`Section` primitives. |
| `StatusPill` / `TonePill` | `StatusPill` maps state strings to translated labels and state tones; `TonePill` renders the shared tone pill. `PILL_TONE_CLASSES` remains available for composite/link pills. | Likely wraps or aliases a future lower-level `Pill`, preserving the state mapping contract. |
| `PanelMessage` | Simple notice surface with `muted`, `error`, `success`, and `warning` tones. | Migration bridge to a future `Notice` primitive. Existing tone names must keep working. |
| `PageHeading` / `SectionHeading` | Route and section heading scale. `PageHeading` renders `<h1>`; `SectionHeading` renders `<h2>` by default and accepts `as`. | Migration bridge to future `Page.Title` and `Section.Title` primitives. |
| `Surface` | Low-level framed area with `panel`, `raised`, `subtle`, `inset`, `danger`, `warning`, and `success` variants plus density padding. | Use when `Section` is too opinionated but a tokenized shell is still needed. |
| `Text` | Polymorphic text element with body, muted, caption, label, mono, and heading variants plus semantic tone classes. | Use for routine typography instead of call-site raw text color classes. |
| `Stack` / `Inline` / `Cluster` / `Toolbar` | Small layout helpers for vertical rhythm, inline metadata rows, wrapping clusters, and command rows. | Use for common spacing/alignment without repeating layout class piles. |
| `Page` | Compound page shell: `Page.Root`, `Header`, `HeadingGroup`, `Title`, `Description`, and `Actions`. | Owns route layout, page title copy, description, and actions. |
| `Section` | Compound content section: `Section.Root`, `Header`, `Title`, `Description`, `Actions`, and `Body`. | Owns operational panels and major route content bands. |
| `LinkText` | Tokenized React Router or anchor link text. | Use for inline/navigation links instead of repeating brand hover classes. |
| `Notice` | Tokenized alert/callout surface with `info`, `warning`, `danger`, `success`, and `neutral` tones plus optional actions. | Replaces ad hoc warning/error/success panels and backs `PanelMessage`. |
| `Pill` / `Badge` | Tokenized rounded chips for state, tags, and compact labels. | `TonePill` remains the domain status bridge; new generic chips should use these. |

## Import Policy

New app and plugin code should import these primitives from `@app/components/ui`:

```tsx
import { Button, Input, Page, Section, StatusPill, Text } from "@app/components/ui"
```

DOC-27 primitives are intentionally boring React passthroughs:

```tsx
<Page.Root size="wide">
  <Page.Header>
    <Page.HeadingGroup>
      <Page.Title>Dashboard</Page.Title>
      <Page.Description>Queue and work state</Page.Description>
    </Page.HeadingGroup>
    <Page.Actions>
      <Button>New Job</Button>
    </Page.Actions>
  </Page.Header>

  <Section.Root divided>
    <Section.Header>
      <Section.Title>Work attempts</Section.Title>
    </Section.Header>
    <Section.Body padding="sm">
      <Text muted>No attempts yet.</Text>
    </Section.Body>
  </Section.Root>
</Page.Root>
```

Existing imports from `@app/components/Button` or nearby relative paths remain supported while pages migrate incrementally. Do not redesign callers as part of an import-only migration.

## Inventory Notes

The initial audit found the listed primitives used across core routes such as dashboard, job detail, repository settings, admin pages, chat panels, and design-system preview, plus plugins such as scheduled tasks, design docs, build cache, test insights, git history, and agent activity. That spread makes a stable barrel import useful immediately, while the current component implementations preserve the existing visual behavior.

Component gallery work can live in the `syrus_dev` plugin later.
