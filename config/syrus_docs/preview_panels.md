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

`PreviewPanel` (`belongs_to :chat_session`) has an `open`/`closed` state and a
derived URL, `preview_url(base_domain, scheme: "http") =
"<scheme>://preview-panel-<id>.<base_domain>"`. The chat payload serializer
(`ChatSerialization#preview_panels_json`) passes `scheme: request.ssl? ?
"https" : "http"` so the returned URL always matches the scheme of the page
embedding it — an `http://` URL inside an `<iframe src>` on an https page is
blocked by browsers as mixed active content, even though the same URL loads
fine via direct top-level navigation. `PreviewEnvironment#preview_url` has the
identical hardcoded-`http://` shape but is only ever opened via direct
top-level navigation (never embedded), so it doesn't need the same fix.

File attachments live one level down, on `PreviewPanelVersion` (`belongs_to
:preview_panel`, `has_many_attached :files`, ordered newest-first by
default) — one row per published revision, following the same append-only
pattern as `WhiteboardSnapshot`. `PreviewPanel#current_version` is the first
(newest) row; `PreviewPanel#file_for(relative_path, version: nil)` resolves a
file within a version, defaulting to the current one. Retention is
indefinite — same cost/retention posture as ordinary attachments; there is no
pruning job. `PreviewPanel::Service` is the sole sanctioned mutation path:

- `open!(chat_session:, title:, files: {})` — creates an open panel and its
  first version.
- `#update!(files:)` — publishes a new `PreviewPanelVersion` snapshot from the
  given files via `PreviewPanel#create_version!`. Prior versions and their
  attachments are left intact and stay servable by id — this is what makes
  version history possible, unlike the model's old purge-and-reattach
  `replace_files!` behavior.
- `#close!` — transitions the panel to `closed`.
- `#update_visibility!(visibility)` — switches `PreviewPanel#visibility`
  between `"private"` (the default) and `"public"`. See "Sharing" below.

Every mutation broadcasts an `AppUserChannel` app event
(`resource: "chat"`, `changed: ["preview_panels"]`) so the chat sidebar
updates live.

## Routing: `PreviewProxyMiddleware`

`PreviewProxyMiddleware` gets a `preview-panel-<id>.<base_domain>`
host-matching branch alongside its existing `preview-<job_id>` (running
process) branch. For a panel request it looks up the open `PreviewPanel` by
id, checks access (see "Sharing" below), resolves which `PreviewPanelVersion`
to serve from an optional `?v=<version_id>` query param (defaulting to
`panel.current_version`, the latest, when absent or when the id doesn't
belong to the panel), resolves the request path against that version's
attached files by their stored `relative_path` blob metadata (ActiveStorage
sanitizes `/` out of plain filenames, so lookup can't use `blob.filename`),
defaulting a blank or root path to `index.html`, and streams the matching
blob with an inferred content type. It reuses the same `PREVIEW_CSP` header
the process-proxy branch sets. Origin isolation (a distinct subdomain per
panel, not same-origin-with-sandbox) is required because a sandboxed
iframe's restrictions only protect framed content, not a browser tab
navigated directly to a copied preview URL.

## Sharing: private vs public visibility

`PreviewPanel#visibility` is `"private"` (the default) or `"public"` — there
is no third "shared with other Syrus users" tier; that would need a much
heavier cross-origin auth exchange for little added value over these two.
"Private" means anyone who can already open the panel's chat session; "public"
is an explicit opt-in that serves the panel to anyone with the URL, matching
the panel proxy's original (unintentionally open) behavior.

The panel subdomain is a different browser origin with no shared session
cookie, so "private" access needs its own plumbing:

- `PreviewPanel::AccessToken` issues a short-lived signed token (panel id +
  expiry) via `Rails.application.message_verifier(:preview_panel_access)` —
  stateless, so there's nothing to persist or prune; `MessageVerifier`'s own
  `expires_in` enforces the TTL. Default TTL is 24 hours, configurable via
  `SYRUS_PREVIEW_PANEL_TOKEN_TTL_HOURS` (same ENV-constant pattern as
  `SYRUS_PREVIEW_BASE_DOMAIN`).
- `POST /api/v1/app/chats/:id/preview_panels/:panel_id/token` mints a token.
  Authorization mirrors whatever already decides a chat is viewable rather
  than a new membership rule: `Current.user.accessible_chat_sessions` (the
  same check `SpaController#require_chat_owner` uses), or the chat's
  `share_token` presented as a `share_token` param (the same proof
  `SharedChatsController` accepts) — so group-chat participation or shared
  links inherit panel access automatically instead of needing a second
  update. Returns 422 for an already-public panel (no token needed).
- The chat frontend (`WorkspacePanels.tsx`) requests this token once when a
  private panel's iframe mounts (`usePreviewPanelAccessToken`) and appends it
  to the iframe `src` as `?token=`, alongside the version `?v=` param. There
  is deliberately no silent background refresh — on expiry the panel just
  stops resolving until the chat is reloaded, which re-mints a fresh token.
- **Token-to-cookie handoff**: a multi-file mockup's follow-up same-origin
  requests (CSS, JS, images, internal links) never carry the original
  query-string token. On the first request that presents a valid token —
  either the `?token=` query param or the cookie from an earlier request —
  `PreviewProxyMiddleware#serve_panel` sets a signed, `HttpOnly`,
  `SameSite=None` cookie (`_syrus_preview_panel_access`) scoped to the
  panel's own `preview-panel-<id>.<base_domain>` origin (no `Domain`
  attribute, so it never leaks to sibling panels or the parent domain).
  Subsequent same-origin requests within that iframe are authorized via the
  cookie without the token being rewritten into every internal link.
  `SameSite=None` requires the `Secure` attribute in modern browsers, so
  this cookie handoff only reliably works over https; over plain http (local
  dev's `lvh.me` default) a private panel's *first* request still works via
  the query token, but purely-cookie-authorized follow-up requests may be
  dropped by the browser.
- `public` panels skip the token/cookie check entirely in
  `PreviewProxyMiddleware#serve_panel` and are always servable.

`PreviewPanel::Service#update_visibility!(visibility)` is the sanctioned
mutation path (validates against `PreviewPanel::VISIBILITIES`, persists, and
broadcasts the same `preview_panels` app event as every other panel
mutation), invoked via `PATCH /api/v1/app/chats/:id/preview_panels/:panel_id`.

## Chat sidebar UI

`workspaceTabs.ts` has a `PreviewTab` variant (`preview:<id>`) alongside the
sidebar's other, singleton, static tab kinds. `WorkspacePanels.tsx` renders
one tab strip entry per open panel and, for the active panel, a small toolbar
strip above the iframe, left to right: a version selector dropdown (hidden
when the panel only has one version), a share control (`PreviewShareControl`)
toggling private/public visibility, an export-as-zip button, and an "open in
new tab" button, followed by a sandboxed iframe (`allow-scripts`, deliberately
no `allow-same-origin`) pointed at the panel's per-instance subdomain. The
version selector lists `panel.versions` newest-first (each labeled "Latest" /
"Version N" with a relative timestamp); switching versions updates the iframe
`src`'s `?v=` param (triggering a reload), the open-in-new-tab link, and the
export link, so all three always act on whichever version is currently
selected rather than hardcoding the latest. The share control shows the
current visibility, offers a private/public toggle backed by
`PATCH .../preview_panels/:panel_id`, and — only once the panel is public —
a "Copy link" action that copies `panel.url` verbatim (no token needed to
view it). While a private panel's access token is still loading, the iframe
and "open in new tab" link are held back (a pending message and a disabled
affordance, respectively) rather than firing an unauthorized request. Chat
payload serialization includes `preview_panels` (`id`, `title`, `file_count`,
`url`, `visibility`, `app_close_path`, `app_visibility_path`,
`app_export_path`, `app_token_path`, `current_version_id`, `versions` — each
`{ id, created_at }`, newest-first) so opening or closing a panel, publishing
a new version, or switching visibility shows up live through the existing
app-events refresh path. Closing a tab calls `DELETE
/api/v1/app/chats/:id/preview_panels/:panel_id`, which drives
`PreviewPanel::Service#close!` — the panel actually stops resolving
server-side rather than just hiding client-side.

## Exporting a version as a zip

The export button is a plain authenticated link (no client-side blob
assembly) pointed at `GET
/api/v1/app/chats/:id/preview_panels/:panel_id/export`, carrying the
currently selected version's id as `?v=<version_id>` the same way the
iframe/proxy URL does (defaulting to `panel.current_version` when omitted or
when the id doesn't belong to the panel, mirroring
`PreviewProxyMiddleware#resolve_panel_version`). Unlike the sandboxed
`preview-panel-*` proxy origin (which has no auth check at all — see below),
export runs through the normal authenticated `ChatsController` action scoped
via `Current.user.accessible_chat_sessions`, since this is an operator
download action, not part of the iframe's own access model.
`PreviewPanel::ZipExporter` streams every attachment on the resolved
`PreviewPanelVersion` into a `Zip::OutputStream` keyed by each blob's stored
`relative_path` metadata (preserving directory structure), and the controller
sends the result with `send_data(..., disposition: "attachment")` so the
browser downloads rather than tries to render the archive inline. Requires
the `rubyzip` gem (declared explicitly in the `Gemfile` — it was previously
only a transitive dependency of `docx`/`selenium-webdriver`).

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
  with it, publishing a new `PreviewPanelVersion` snapshot — call repeatedly
  to iterate in place; each call adds to the panel's version history rather
  than overwriting it, so earlier iterations stay servable by version id.
  Requires `entry_file` (default `index.html`) to already exist among the
  scratch files before publishing, since the panel always serves
  `index.html` for its root URL regardless of `entry_file`.
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
