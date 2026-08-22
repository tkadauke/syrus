# Preview Panels

Preview panels let a planning-mode chat agent build and show a live HTML/CSS/JS
mockup or interactive widget page directly in the operator's chat sidebar,
without ever writing to an attached repository checkout. Unlike [Preview
Environments](preview_environments.md), which proxy to a running process
spawned from a PR branch, a preview panel just serves ActiveStorage-attached
static files — there is no process behind it. A chat can have several panels
open at once, each independently closeable, which is why `PreviewPanel` is a
`belongs_to :chat_session` model rather than a per-chat singleton like the
other workspace tabs.

## Model and mutation path

`PreviewPanel` (`belongs_to :chat_session`, `has_many_attached :files`) has an
`open`/`closed` state and a derived URL,
`preview_url(base_domain) = "http://preview-panel-<id>.<base_domain>"`,
mirroring `PreviewEnvironment#preview_url`. `PreviewPanel::Service` is the
sole sanctioned mutation path:

- `open!(chat_session:, title:, files: {})` — creates an open panel.
- `#update!(files:)` — replaces the full attached file set (purge + reattach,
  not append, so a file removed from a later revision stops being served).
- `#close!` — transitions the panel to `closed`.

Every mutation broadcasts an `AppUserChannel` app event
(`resource: "chat"`, `changed: ["preview_panels"]`) so the chat sidebar
updates live.

## Routing: `PreviewProxyMiddleware`

`PreviewProxyMiddleware` gets a `preview-panel-<id>.<base_domain>`
host-matching branch alongside its existing `preview-<job_id>` (running
process) branch. For a panel request it looks up the open `PreviewPanel` by
id, resolves the request path against the panel's attached files by their
stored `relative_path` blob metadata (ActiveStorage sanitizes `/` out of
plain filenames, so lookup can't use `blob.filename`), defaulting a blank or
root path to `index.html`, and streams the matching blob with an inferred
content type. It reuses the same `PREVIEW_CSP` header the process-proxy
branch sets. Origin isolation (a distinct subdomain per panel, not
same-origin-with-sandbox) is required because a sandboxed iframe's
restrictions only protect framed content, not a browser tab navigated
directly to a copied preview URL.

## Chat sidebar UI

`workspaceTabs.ts` has a `PreviewTab` variant (`preview:<id>`) alongside the
sidebar's other, singleton, static tab kinds. `WorkspacePanels.tsx` renders
one tab strip entry per open panel and displays the active panel's content in
a sandboxed iframe (`allow-scripts`, deliberately no `allow-same-origin`)
pointed at the panel's per-instance subdomain. Chat payload serialization
includes `preview_panels` (`id`, `title`, `file_count`, `url`,
`app_close_path`) so opening or closing a panel shows up live through the
existing app-events refresh path. Closing a tab calls
`DELETE /api/v1/app/chats/:id/preview_panels/:panel_id`, which drives
`PreviewPanel::Service#close!` — the panel actually stops resolving
server-side rather than just hiding client-side.

## Chat MCP tools (`preview_tools` plugin)

Planning mode has no Write/Edit tools at all (see `Prompts::ChatSystem`) —
attached repository checkouts are read-only for a planning agent. The bundled
`preview_tools` plugin (`Syrus::Plugin::ChatMcpToolSet`,
`PreviewTools::ChatToolSet`) adds a narrow, separately-jailed alternative
scoped only to a preview panel's own scratch directory:

- `write_preview_file(panel_id, path, content)` / `edit_preview_file(panel_id,
  path, old_string, new_string, replace_all:)` — same semantics as the
  harness's own Write/Edit tools (edit requires `old_string` to be unique
  unless `replace_all` is set), but every path is resolved and jailed to
  `<ChatWorkspace.path_for(chat_session)>/previews/<panel_id>/`
  (`PreviewTools::ScratchDirectory`, mirroring the cleanpath + prefix-check
  pattern `ChatWorkspace#safe_checkout_path` uses for repository paths) — no
  `../` traversal, no absolute paths elsewhere, and `panel_id` is only ever
  taken from a panel the calling chat session actually owns, never
  interpolated from a raw client-controlled string.
- `show_preview(panel_id?, title, entry_file: "index.html")` — without
  `panel_id`, opens a new empty panel via `PreviewPanel::Service.open!` and
  returns its id (there are no scratch files yet for a not-yet-created
  panel's id, so the first call is always empty by construction); write
  files into that panel's scratch directory, then call `show_preview` again
  with the same `panel_id` to publish them. With `panel_id`, walks the
  panel's current scratch directory and calls `PreviewPanel::Service#update!`
  with it, replacing the previously published file set — call repeatedly to
  iterate in place. Requires `entry_file` (default `index.html`) to already
  exist among the scratch files before publishing, since the panel always
  serves `index.html` for its root URL regardless of `entry_file`.
- `close_preview(panel_id)` — calls `PreviewPanel::Service#close!`.

Both "quick interactive widget page" and "freeform layout mockup" go through
the same `show_preview` call — the only difference is what the agent writes
into the scratch directory (e.g. a CDN `<script>`/`<link>` tag for a widget
library inside the generated HTML itself, vs. hand-authored layout). No new
frontend dependency or bundled widget library is needed.

The scratch directory and the panel's attachments persist for the life of
the chat session — cleanup rides along with whatever already garbage-collects
`chat-workspaces/<id>` (`ChatWorkspace.prune_idle!`), rather than a second
cleanup path.

Available only to planning-mode chat sessions (`chat_session.coding?` and
`chat_session.local?` are both false) — Coding Mode and Local Mode already
have real Write/Edit tools against a writable checkout and don't need a
scratch alternative.

## Configuration

Reuses `SYRUS_PREVIEW_BASE_DOMAIN` (see [Preview
Environments](preview_environments.md#configuration)) — no separate
environment variable.
