# Theming Tools

The `theming_tools` plugin (`plugins/theming_tools/`) gives the Syrus Chat
agent a `preview_theme` MCP tool: the agent can draft a candidate color
theme and pop it open for the user against the real Style Guide page
(`/design_system`, `app/frontend/routes/DesignSystem.tsx`), so a palette can
be judged against actual `Button`/`Input`/`Card`/etc. components instead of
a recreated mockup. It is a self-contained Rails engine plugin, installed
but disabled by default (`default_enabled: false`, `disableable: true`,
category `mcp_tool_set`), matching `mysql_db_browser`'s opt-in-experimental
precedent. Enable it from **Admin → Plugins** (`/admin/plugins`).

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

Contrast validation is out of scope for this tool (tracked as follow-up work
alongside `install_theme` and theme CRUD); `preview_theme` only checks that
the token shape is complete, not that it is legible.

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
