# UI Component Contracts

`@app/components/ui` is the stable public import surface for shared Syrus frontend primitives. It starts as a compatibility package over the existing components so core routes and plugins can migrate imports without visual churn.

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

## Import Policy

New app and plugin code should import these primitives from `@app/components/ui`:

```tsx
import { Button, Input, PageHeading, StatusPill } from "@app/components/ui"
```

Existing imports from `@app/components/Button` or nearby relative paths remain supported while pages migrate incrementally. Do not redesign callers as part of an import-only migration.

## Inventory Notes

The initial audit found the listed primitives used across core routes such as dashboard, job detail, repository settings, admin pages, chat panels, and design-system preview, plus plugins such as scheduled tasks, design docs, build cache, test insights, git history, and agent activity. That spread makes a stable barrel import useful immediately, while the current component implementations preserve the existing visual behavior.

Near-term DOC-27 work should add new semantic primitives beside this barrel, starting with `Surface`, `Text`, `Stack`, `Inline`, `Toolbar`, `Page`, `Section`, `LinkText`, and `Notice`. The design-doc thread chose `components/ui`; component gallery work can live in the `syrus_dev` plugin later.
