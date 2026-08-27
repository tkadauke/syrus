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

The `Theme` model and its 13-key token schema (`brand`, `brand-emphasis`,
`surface`, `surface-raised`, `border`, `text-primary`, `text-secondary`,
`success`, `warning`, `danger`, `info`, `neutral`, `on-brand`, each with a
`light` and `dark` value) live in the main app (`app/models/theme.rb`), not
in this plugin — same "models stay in core" precedent `WhiteboardSnapshot`
sets for `whiteboard_tools`. This plugin only owns the tool surface and the
broadcast that opens the preview.

## `preview_theme`

`ThemingTools::PreviewThemeTool`
(`plugins/theming_tools/app/services/theming_tools/preview_theme_tool.rb`)
accepts a `name` and any subset of the token keys under `light`/`dark`. Any
token left unspecified defaults to the value from the calling user's
currently active theme (`User#color_theme`, falling back to nothing if the
user has none), so the agent can iterate on just a couple of tokens at a
time instead of restating the full palette on every call.

The tool upserts one draft `Theme` row per user — found by a deterministic
per-user slug (`preview-draft-<user_id>`), not by the theme's display name —
so repeated calls from the same user update that row in place instead of
creating a new one each iteration. The row is always `built_in: false` and
owned by the chat's user (`ChatSession#user`). If the merged token set is
still missing a key after defaulting (e.g. the user has no active theme and
the agent didn't supply that key), the row fails `Theme`'s validation and
the tool returns an error without saving or broadcasting anything — safe to
retry.

`preview_theme` itself only checks that the token shape is complete, not
that it is legible -- a preview is allowed to show an illegible palette so
the user/agent can see the problem and iterate; the contrast gate lives on
the tools that actually persist a theme (below).

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
all three built-in themes (`db/seeds/themes.rb`) pass with margin. It
returns `[]` when every pairing passes (or when `tokens` isn't shaped
correctly yet -- that's `#tokens_has_required_shape`'s job to flag), or an
array of issue hashes (`mode`, `foreground`, `background`,
`foreground_color`, `background_color`, `ratio`, `required_ratio`,
`message`) otherwise. It is a plain instance method, not an
`ActiveRecord` validation, so `preview_theme` (and any other direct
`Theme#save`) is unaffected -- only tools that gate on it explicitly reject.

## `install_theme`

`ThemingTools::InstallThemeTool`
(`plugins/theming_tools/app/services/theming_tools/install_theme_tool.rb`)
persists a theme as the calling user's active `color_theme`. Accepts either
`theme_id` (any theme the user can select --
`Theme.selectable_by(user)`, covering both a prior `preview_theme` draft and
any built-in/owned theme) or a full `name` + complete `light`/`dark` token
payload to create a new theme. Either way, `Theme#contrast_issues` runs
first; if it returns any issues the tool rejects with a specific message
naming every failing pair, its actual ratio, and the required ratio (e.g.
"light text-secondary (#9ca3af) on surface (#ffffff) has contrast 2.3:1,
needs at least 4.5:1 for WCAG AA") instead of silently persisting an
illegible theme. On success it sets `User#color_theme` to the resolved
theme and returns its `public_payload`.

## `list_user_themes` / `update_user_theme` / `delete_user_theme`

`ThemingTools::ListUserThemesTool` returns the calling user's own
non-built-in themes (`public_payload` for each), never another user's
themes or built-ins.

`ThemingTools::UpdateUserThemeTool` renames and/or adjusts token values on
one of the user's own custom themes -- omitted token keys keep their
current value, mirroring `preview_theme`'s partial-override merge. It
re-runs `Theme#contrast_issues` before saving and rejects (with the same
specific per-pair message `install_theme` uses) rather than letting an edit
make a previously-legible theme illegible; the theme is left unchanged on
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
tabs like `preview_tools`' panel are a sidebar tab, not an overlay. On a
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
