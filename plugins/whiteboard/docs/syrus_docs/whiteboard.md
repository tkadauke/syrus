# Whiteboard

The `whiteboard` plugin (`plugins/whiteboard/`) adds a shared Excalidraw
canvas per chat, plus MCP drawing tools so chat agents can sketch alongside
operators. It is default-ON, customer-facing, category `agent_capability`,
`disableable: true`, providing `chat_mcp_tool_set: "Whiteboard::ChatToolSet"`,
`workspace_tab: "Whiteboard::WorkspaceTabs"`,
`chat_media_source: "Whiteboard::MediaSource"`,
`chat_payload_contributor: "Whiteboard::PayloadContributor"`, and
`chat_prompt_injector: "Whiteboard::PromptSection"`.

## Schema

- `whiteboard_boards` (renamed from `whiteboards` in a later migration to
  carry the plugin's own table prefix, per `bin/check-plugin-model-namespaces`)
  — one row per `chat_session`, via `Whiteboard::Board`. Carries `scene_json`
  (Excalidraw `elements`/`appState`/`files`), an integer `version` for
  optimistic concurrency, and `last_edited_at`.
- `whiteboard_snapshots` — named point-in-time copies of a scene
  (`Whiteboard::Snapshot`), one row per save. `snapshot_kind` is one of
  `manual` (explicit `save_canvas` call), `auto_clear` (taken automatically
  before `clear_canvas` empties the board), or `auto_before_load` (taken
  automatically before `load_canvas` replaces the board in `replace` mode).

`ChatSession has_one :whiteboard` / `has_many :whiteboard_snapshots` are
**not** core associations — the plugin injects them at boot via an `always`
effect (not `while_enabled`), because disabling the plugin should stop the
canvas from being drawn on without deleting boards/snapshots that already
exist; those still need to be cleaned up when their chat is deleted
regardless of plugin state. `Whiteboard::DataCleanup` registers both
deletions with core's `Syrus::DataCleanup` registry for that reason.

MySQL 8 cannot default a JSON column, so `Board#seed_empty_scene_json`
(an `after_initialize` callback on new records) seeds `EMPTY_SCENE` — an
empty `elements` array with `appState`/`files` hashes — the same pattern
other JSON-column models in this codebase use.

## Canvas model and mutation (`Whiteboard::Canvas`, `Whiteboard::Board`)

Every MCP tool that changes the scene goes through `Canvas.mutate`, which:

1. Locks the `Board` row (`lock!`) inside a transaction — every tool call is
   serialized per chat, so two concurrent agent draws (or an agent draw
   racing an operator's own edit through the REST PATCH) can't silently
   clobber each other.
2. Deep-dups the current scene, yields `(elements, scene)` to the caller's
   block to mutate in place, then re-validates the element count against
   `Whiteboard::Board::MAX_ELEMENTS` (1000) — over the limit raises
   `Canvas::ElementLimitExceeded`, surfaced to the agent as a tool error
   rather than a hard failure.
3. Persists the new `scene_json`, increments `version`, stamps
   `last_edited_at`, and broadcasts the updated scene over `AppEvents`
   (`resource: "chat"`, `changed: ["whiteboard"]`) so every connected
   browser tab updates live.

`Canvas` also owns Excalidraw element construction: `shape_element` (
rectangle/ellipse/diamond, plus a `sticky` pseudo-type that renders as a
yellow rectangle with an amber border), `line_element`/`freedraw_element`
(point-array based), `frame_element`, `embed_element`, `image_element` (with
a paired `file_record` for the binary-files map), `text_element`, and
`bound_label_element` (a separate `text` element bound via `containerId` —
Excalidraw has no native "label" field on a shape). `base_element` fills in
every visual-style default (`opacity`, `strokeWidth`, `strokeStyle`,
`roughness`, `fillStyle`, etc.) explicitly, because Excalidraw's
`updateScene` broadcast-apply path takes elements as-is without normalizing
them — omitting these renders the element invisible even though a page
*reload* (which goes through `initialData`, which does normalize) would look
fine. `remove_element!` also strips dangling `boundElements` references and
deletes any arrow bound to the removed element;
`recalibrate_bound_arrows!`/`recalibrate_arrow!` re-derive a bound arrow's
geometry from its endpoints' current centers after a move.

## MCP tools (`Whiteboard::ChatToolSet`)

Fifteen tools, all tier `:deferred` (available in every chat once the
deferred tool tier loads — no feature flag or role gate beyond that):

- **`read_scene`** — returns the current scene (cheap; recommended whenever
  the operator references something they drew or moved).
- **`draw_shape`** / **`draw_text`** / **`draw_line`** / **`draw_arrow`** /
  **`draw_freedraw`** / **`draw_frame`** / **`draw_embed`** /
  **`draw_image`** — append one high-level element. `draw_arrow` produces a
  *bound* arrow that tracks two existing elements' centers as they move —
  its endpoints are centers, not edges, so it visually cuts through shape
  interiors and labels; the system prompt steers the agent toward
  `draw_line` with `type: "arrow"` and manually-computed edge-anchored
  points for diagrams connecting labeled shapes instead. `draw_arrow`'s
  `label` parameter does not currently render visible text — the agent is
  told to add a separate `draw_text` call near the midpoint.
- **`move_element`** / **`delete_element`** — mutate or remove an existing
  element by id.
- **`update_scene`** — full-scene replacement, reserved for cases the
  high-level tools can't express (an Excalidraw feature with no dedicated
  tool, or a genuine full-scene swap).
- **`save_canvas`** — snapshots the current scene as `kind: "manual"`
  (no-ops with `saved: false` if the canvas is empty).
- **`clear_canvas`** — auto-snapshots the current scene (`kind:
  "auto_clear"`) before clearing, when non-empty, so a clear is always
  recoverable via `load_canvas`.
- **`load_canvas`** — restores a saved snapshot, in one of two modes:
  **merge** (default) deep-copies the snapshot's elements with **freshly
  generated ids** (`remap_snapshot_elements`, which also remaps every
  internal reference — `containerId`, `frameId`, `groupIds`,
  `boundElements`, `startBinding`/`endBinding`) and appends them to the
  current scene, so loading the same snapshot twice never collides ids;
  **replace** auto-snapshots the current scene first (`kind:
  "auto_before_load"`, when non-empty) and then swaps the whole
  `elements`/`appState`/`files`.

Tools do **not** persist a separate structured `tool_use` row in the chat —
the agent's own stream-json `log_sink` already emits an abbreviated
`tool_use` line (e.g. `● draw_shape(rectangle)`) per MCP call; an earlier
version double-logged this and was simplified.

## Chat surface integration

- **Workspace tab** (`Whiteboard::WorkspaceTabs`) — `whiteboard.canvas`,
  available in every chat unconditionally (matching the tab's previous
  hardcoded presence before it moved into this plugin). The frontend
  (`WhiteboardTab.tsx`) renders the Excalidraw canvas and owns its own
  fullscreen state as a fixed full-viewport portal into `document.body`
  (Escape or the toggle exits) — the `workspace_tab` extension point only
  hands a component `payload`, with no fullscreen prop/callback on that
  contract, unlike the old core-threaded layout-shift approach.
- **Chat payload** (`Whiteboard::PayloadContributor`) — adds a top-level
  `whiteboard: { version, elements, appState, files, loaded }` key. The full
  scene ships **only** when the request explicitly asks for it
  (`include_whiteboard` param) since it can be large; otherwise `loaded:
  false` with an empty default scene. Also contributes the
  `app_whiteboard_path` route and a `whiteboard_snapshot_count` for chat list
  payloads. The MySQL scope uses an explicit `FORCE INDEX` hint on
  `chat_session_id` — MySQL picks a worse plan without it on chats with many
  rows.
- **Chat media source** (`Whiteboard::MediaSource`) — registers the
  `"snapshot"` chat-media kind (`snapshot:<id>` refs), so a snapshot can be
  attached to a Job proposal like any other chat attachment
  (`attach_chat_media` creates a `pending_snapshot` `JobAttachment`).
  `chat_media_panel` feeds the media tab's whiteboard section: every
  snapshot plus a `whiteboard_has_unsaved_content` flag (true when the live
  canvas has non-deleted elements and either no manual snapshot exists yet,
  or the board was edited after the latest manual snapshot was taken).
  `chat_media_context` reports the live element count so an agent deciding
  whether to `save_canvas` can tell an empty board from one worth saving.
- **System prompt section** (`Whiteboard::PromptSection`) — injects the
  whiteboard's usage guidance into the chat agent's system prompt: use it
  only when the operator explicitly asks for a canvas/diagram/sketch, prefer
  the high-level draw tools over raw `update_scene`, and prose still wins
  for lists/decisions/code references while canvas wins for spatial
  relationships.

## REST endpoints

`Api::V1::App::ChatWhiteboardsController` (`GET`/`PATCH
/api/v1/app/chats/:id/whiteboard`) backs the operator-facing (non-agent)
editing path. `PATCH` takes `elements`/`appState`/`files` plus an
`expected_version` — under `chat_session.with_lock`, a version mismatch
returns `409 Conflict` with the current server state rather than silently
overwriting concurrent changes (the same optimistic-concurrency contract
`Canvas.mutate`'s row lock enforces for the MCP tool path, just expressed as
an explicit client-supplied version instead of always-succeeds-because-
serialized). Exceeding `MAX_ELEMENTS` returns `422`.

`Api::V1::App::WhiteboardSnapshotsController` exposes list/show/create under
`/api/v1/app/chats/:chat_id/whiteboard_snapshots`, mirroring
`Whiteboard::Snapshot.create_from_scene!`'s validation (`ArgumentError` →
`400`, `ActiveRecord::RecordInvalid` → `422`).

## What's not here

Whiteboard snapshots are collaboration artifacts, not source files — the
plugin does not push scene state into repository code or PR diffs. Important
implementation decisions made while sketching should still be captured in
Jobs, Epics, or repository docs, not left to live only as canvas state.
