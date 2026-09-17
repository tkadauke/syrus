# Theming Tools

The `theming_tools` plugin (`plugins/theming_tools/`) gives the Syrus Chat
agent tools to draft, preview, install, and manage custom color themes:
`preview_theme` drafts a candidate theme and pops it open for the user
against the real Style Guide page (`/design_system`,
`app/frontend/routes/DesignSystem.tsx`), so a palette can be judged against
actual `Button`/`Input`/`Card`/etc. components instead of a recreated
mockup; `install_theme` persists a theme (contrast-checked first) as the
user's active theme; `list_user_themes`, `update_user_theme`, and
`delete_user_theme` manage the user's own custom themes. It is a
self-contained Rails engine plugin, installed but disabled by default
(`default_enabled: false`, `disableable: true`, category `mcp_tool_set`),
matching `mysql_db_browser`'s opt-in-experimental precedent. Enable it from
**Admin → Plugins** (`/admin/plugins`).

The `Theme` model and its 13-key color token schema (`brand`, `brand-emphasis`,
`surface`, `surface-raised`, `border`, `text-primary`, `text-secondary`,
`success`, `warning`, `danger`, `info`, `neutral`, `on-brand`, each with a
`light` and `dark` value), plus the non-color `Theme::EXTENDED_TOKEN_GROUPS`
(`shape`, `shadow`, `spacing`, `density`, `typography` — see below) live in
the main app (`app/models/theme.rb`), not in this plugin — same "models stay
in core" precedent `WhiteboardSnapshot` sets for `whiteboard`. This plugin
only owns the tool surface and the broadcast that opens the preview.

## Non-color (extended) token groups

`Theme::EXTENDED_TOKEN_GROUPS` layers shape, elevation, layout rhythm, and
typography on top of the original color-only model, unlike `light`/`dark`
these are not split by mode (a theme's radius/spacing/density/typography
doesn't change between light and dark):

- `shape` — `radius-control`, `radius-panel`, `radius-pill`, `border-width`
- `shadow` — `shadow-panel`
- `spacing` — `space-page-x`, `space-page-y`, `space-section`, `space-section-compact`
- `density` — `control-height-sm`, `control-height-md`, `table-row-height`
- `typography` — `font-sans`, `font-mono`, `text-page-title`, `text-section-title`, `text-body`, `text-caption`

Every UI primitive (`Button`, `Surface`, `Page`, etc.) is styled from these
as CSS custom properties (`var(--radius-control)`, `var(--space-page-x)`,
...), same mechanism as the color tokens. A theme that omits a group
entirely, or omits individual keys within a present group, falls back to
`Theme::DEFAULT_EXTENDED_TOKENS` per key via `Theme#tokens_with_defaults` --
so every color-only theme that predates this token expansion (all 18
original built-ins) keeps rendering exactly as before with no data
migration. `Theme#public_payload` always returns the fully-defaulted view,
so every tool response below carries all five groups regardless of what the
underlying theme actually stored.

`ThemingTools::ExtendedTokenSchema`
(`plugins/theming_tools/app/services/theming_tools/extended_token_schema.rb`)
is the shared JSON-schema fragment (`GROUP_PROPERTIES`, one optional object
property per group) and partial-override merge helper (`merge_groups`) that
`preview_theme`, `install_theme`, and `update_user_theme` all build their
`shape`/`shadow`/`spacing`/`density`/`typography` input-schema properties
and merge behavior from, so the three tools can't drift out of sync with
each other or with `Theme::EXTENDED_TOKEN_GROUPS`. `merge_groups` mirrors
the existing `light`/`dark` partial-override merge: an omitted key keeps
whatever the merge's baseline tokens hash had for it, and a group with
neither a baseline value nor a supplied override is left out of the result
entirely (rather than baking in the current defaults), so
`Theme#tokens_with_defaults` still supplies it at read time.

The built-in **Console** theme (`db/seeds/themes.rb`) exists specifically to
prove this model outside of colors: sharp corners (`radius-*` near zero),
no panel shadow, a tighter spacing/density scale, and an all-monospace
typography stack, layered onto a color palette borrowed from Slate (already
contrast-checked) so only the non-color tokens are actually novel. Selecting
it from the account sidebar's color-theme picker (`nav:color_theme`,
`AppChromeV2.tsx`'s `ColorThemePicker`) demonstrates every extended token
group changing at once across the live app, not just a preview.

## Settings page

Users can manage their own persisted custom themes from **Settings →
Themes** (`/settings/themes`). The page lists only non-built-in themes owned
by the signed-in user, can create a new custom theme by cloning the active
theme's token values, supports renaming/deleting, exposes hand-edit controls
for all 13 light and dark token values, and uses the same native
drag-and-drop reorder pattern as the dashboard smart-folder sidebar. Edits
reuse the app `ThemeContext#previewColorTheme` path for local CSS preview while saving
through the REST API (`/api/v1/app/themes`, `/api/v1/app/themes/:id`, and
`/api/v1/app/themes/reorder`). If the backend rejects a save for WCAG AA
contrast, the returned issue payload is displayed beside every affected token
field.

## `preview_theme`

`ThemingTools::PreviewThemeTool`
(`plugins/theming_tools/app/services/theming_tools/preview_theme_tool.rb`)
accepts a `name`, any subset of the color token keys under `light`/`dark`,
and any subset of the non-color `shape`/`shadow`/`spacing`/`density`/
`typography` groups (see above). Any color token left unspecified defaults
to the value from the calling user's currently active theme (`User#color_theme`,
falling back to nothing if the user has none); any non-color group/key left
unspecified defaults to the active theme's own value, then to
`Theme::DEFAULT_EXTENDED_TOKENS` — so the agent can iterate on just a couple
of tokens (color or non-color) at a time instead of restating the full
palette and token set on every call.

The tool upserts one draft `Theme` row per user — found by a deterministic
per-user slug (`preview-draft-<user_id>`), not by the theme's display name —
so repeated calls from the same user update that row in place instead of
creating a new one each iteration. The row is always `built_in: false` and
owned by the chat's user (`ChatSession#user`). If the merged token set is
still missing a key after defaulting (e.g. the user has no active theme and
the agent didn't supply that key), the row fails `Theme`'s validation and
the tool returns an error without saving or broadcasting anything — safe to
retry.

`preview_theme` checks that the token shape is complete (a validation
failure blocks the save), but never blocks on legibility -- a draft is
explicitly allowed to move through illegible intermediate states while the
user/agent iterates on one token pair at a time. It does, however, run the
same `Theme#contrast_issues` WCAG AA check `install_theme`/
`update_user_theme` enforce and returns any failing pairs as a
non-blocking `contrast_warnings` array in the tool response (empty when
there are no issues), so the agent finds out about a bad pairing during
iteration instead of only at install time. The `GET /api/v1/app/themes/:id`
endpoint the Style Guide page's `?theme_id=` preview uses returns the same
array (top-level `contrast_warnings`, sibling to `theme`), and
`DesignSystemRoute` renders it as a non-blocking amber `PanelMessage`
banner above the component gallery whenever the previewed theme has issues.
Both callers go through `Theme#contrast_warning_messages` (not
`#contrast_issues` directly) -- a thin wrapper that rescues and logs
instead of raising, since a warning-only surface must never crash on a
malformed/placeholder color value the way `#install_theme`'s hard-reject
path is allowed to assume valid input for.

## Contrast validation (`Theme#contrast_issues`)

`Theme#contrast_issues` (`app/models/theme.rb`) is a plain-Ruby WCAG AA
(4.5:1) relative-luminance contrast check (`app/services/color_contrast.rb`,
no gem) shared by `install_theme` and `update_user_theme`. Per mode
(`light`/`dark`) it checks: `text-primary` and `text-secondary` against
both `surface` and `surface-raised`, plus each status tone
(`success`/`warning`/`danger`/`info`/`neutral`) against its own tinted
"status pill" background. Since an arbitrary user-defined theme has no
Tailwind-style shade scale to draw an exact "-50"/"-950" background from
(the way `StatusPill`'s `TonePill` does), the tinted background is
approximated by alpha-blending the tone color over the theme's own
`surface` at a fixed 6% mix (`Theme::STATUS_TONE_BACKGROUND_TINT_ALPHA`) --
a documented approximation, not a literal Tailwind-scale match, tuned so
all 19 built-in themes (`db/seeds/themes.rb`) pass with margin. It
returns `[]` when every pairing passes (or when `tokens` isn't shaped
correctly yet -- that's `#tokens_has_required_shape`'s job to flag), or an
array of issue hashes (`mode`, `foreground`, `background`,
`foreground_color`, `background_color`, `ratio`, `required_ratio`,
`message`) otherwise. It is a plain instance method, not an
`ActiveRecord` validation, so it never blocks a bare `Theme#save` -- only
tools that explicitly check it before saving (`install_theme`,
`update_user_theme`) reject on failure. `preview_theme` and the Style Guide
preview panel also call it (via `Theme#contrast_warning_messages`, see
below) but only to surface warnings, never to block the save.

## `install_theme`

`ThemingTools::InstallThemeTool`
(`plugins/theming_tools/app/services/theming_tools/install_theme_tool.rb`)
persists a theme as the calling user's active `color_theme`. Accepts either
`theme_id` (any theme the user can select --
`Theme.selectable_by(user)`, covering both a prior `preview_theme` draft and
any built-in/owned theme) or a full `name` + complete `light`/`dark` color
token payload -- optionally plus any subset of the non-color `shape`/
`shadow`/`spacing`/`density`/`typography` groups, each falling back to
`Theme::DEFAULT_EXTENDED_TOKENS` -- to create a new theme. Either way,
`Theme#contrast_issues` runs first (color tokens only); if it returns any
issues the tool rejects with a specific message naming every failing pair,
its actual ratio, and the required ratio (e.g. "light text-secondary
(#9ca3af) on surface (#ffffff) has contrast 2.3:1, needs at least 4.5:1 for
WCAG AA") instead of silently persisting an illegible theme. On success it
sets `User#color_theme` to the resolved theme and returns its
`public_payload`.

## `list_user_themes` / `update_user_theme` / `delete_user_theme`

`ThemingTools::ListUserThemesTool` returns the calling user's own
non-built-in themes (`public_payload` for each, so every response already
includes the fully-defaulted `shape`/`shadow`/`spacing`/`density`/
`typography` groups alongside `light`/`dark`), never another user's themes
or built-ins.

`ThemingTools::UpdateUserThemeTool` renames and/or adjusts color and
non-color token values on one of the user's own custom themes -- omitted
color keys keep their current value, and omitted non-color groups/keys keep
their current value (or the built-in default if the theme never set them),
mirroring `preview_theme`'s partial-override merge. It re-runs
`Theme#contrast_issues` before saving and rejects (with the same specific
per-pair message `install_theme` uses) rather than letting an edit make a
previously-legible theme illegible; the theme is left unchanged on
rejection. Refuses to touch built-in themes or another user's themes.

`ThemingTools::DeleteUserThemeTool` deletes one of the user's own custom
themes. Refuses outright for `built_in: true` themes and for themes owned
by a different user. If the theme being deleted is the user's current
`color_theme`, it first reassigns the user to their default built-in theme
(`Theme.terracotta` -- the same fallback `User#seed_default_color_theme`
uses for new users) so `color_theme_id` never dangles, then destroys the
theme.

## Opening the preview

There is no general "agent opens a popup in the user's chat UI" primitive in
Syrus — `typed_artifacts` render inline in the transcript, and workspace
tabs like `mockups`' panel are a sidebar tab, not an overlay. On a
successful upsert, the tool broadcasts an `AppEvents` app event scoped to
the chat (`resource: "chat"`, `id: <chat_session_id>`, mirroring the pattern
`WhiteboardSnapshot#broadcast_created` and
`BroadcastsJobProgress`'s `job_status_changed` payload use) with
`payload: { action: "open_theme_preview", theme_id:, path: "/design_system?theme_id=<id>" }`.

The frontend (`app/frontend/lib/appEvents.ts`) recognizes that payload
action and re-dispatches it as a `window` `CustomEvent` named
`syrus:theme-preview` — the same "hand off to a `CustomEvent` for state a
query-cache invalidation can't carry" pattern already used for
`syrus:job-status-changed` and `syrus:video-walkthrough`.
`ThemePreviewModal` (`app/frontend/routes/chat/ThemePreviewModal.tsx`),
mounted once inside the chat workspace (`ChatView` in
`app/frontend/routes/Chat.tsx`), listens for that event, filters it to the
currently open chat, and opens a `Modal` (`app/frontend/components/Modal.tsx`)
containing an iframe pointed at the broadcast `path` (route-prefixed via
`withRoutePrefix` for the desktop shell's `/app-shell` mount). The Design
System route itself already reads `?theme_id=` and layers that theme's
tokens over its own root element only (never `document.documentElement`),
so a draft preview can never leak into the surrounding app chrome.

`DesignSystemRoute` (`app/frontend/routes/DesignSystem.tsx`) scopes both the
color tokens (`--color-*`) and the non-color `--radius-*`/`--shadow-panel`/
`--space-*`/`--control-height-*`/`--table-row-height`/`--font-*`/`--text-*`
custom properties onto that same root element, so a `preview_theme` draft
that only tweaks `shape`/`density`/`typography` visibly changes the gallery
too -- tighter buttons, squared-off cards, a different type scale -- not
just swatch colors. A dedicated "Expanded tokens" section below the color
swatches lists every non-color group's resolved values (previewed theme's,
or the page's own live theme when there's no `?theme_id=`) as plain text,
since most of these tokens (font stacks, shadow values) aren't paintable
swatches the way a color is.
