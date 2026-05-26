# Per-repo chat — whiteboard extension

_Captured 2026-05-13. Extension to `docs/plans/per-repo-chat.md`.
Adds a collaborative Excalidraw canvas to the chat page where both
the operator and the embedded agent can sketch architecture
diagrams, UI mockups, flow charts, etc. The chat is the
conversation; the whiteboard is the visual artifact the
conversation refines._

_Status check 2026-05-15: shipped as an extension to the per-repo chat
work. `ChatWhiteboard`, the whiteboard controller/view, chat layout
controllers, and chat MCP canvas tools (`read_scene`, `draw_*`,
`move_element`, `delete_element`, `clear_canvas`, `update_scene`) are
present. Remaining follow-ups are the deferred items below, especially
raster export / `read_canvas_image()` and richer proposal-body image
support._

## Context

Text-only planning conversations hit a wall when the problem is
visual. "Draw what you mean by 'the auth flow'" is faster than a
500-word description, and a back-and-forth sketch session
converges on a design more reliably than back-and-forth prose.
Today the operator would tab over to Excalidraw / Figma / a
napkin; the agent can't see any of it and can't contribute.

This plan folds a shared canvas into the chat page. The agent
gets MCP tools to read and edit the scene; the operator gets a
real Excalidraw embed; their edits flow through the same DB
record. The artifact persists with the chat session, just like
proposals already do.

## Decisions locked

1. **Excalidraw, embedded as a React component.** MIT-licensed,
   published as `@excalidraw/excalidraw`, documented programmatic
   API for pushing scene updates from outside, JSON scene format
   we can store in the DB. Don't build a custom canvas.
2. **One whiteboard per `ChatSession`.** Lifecycles together with
   the chat. "New chat" creates a fresh whiteboard. Per-chat
   matches the existing chat plan's no-archive rule + simplifies
   conflict scope. Per-repo shared whiteboard explicitly rejected.
3. **Sync model: last-writer-wins on a single source of truth.**
   No CRDT, no operational transform. The server's `scene_json`
   column is authoritative; user and agent both push deltas
   through the same endpoint; concurrent edits to the same
   element resolve by latest write on `element.id`. Acceptable
   because most chat sessions have one party drawing at a time.
4. **Agent reads JSON only in v1.** No `read_canvas_image()`
   pixel-render tool. The agent reads the scene structure via
   `read_scene()` and reasons about positions/labels/connections
   from JSON. If that proves insufficient in practice, server-side
   PNG rendering becomes a follow-up (see Deferred). Skipping it
   for v1 sidesteps headless-browser infrastructure that isn't
   in place yet anyway.
5. **Six high-level MCP tools + one raw escape hatch + one
   read.** `draw_shape`, `draw_text`, `draw_arrow`,
   `move_element`, `delete_element`, `clear_canvas` cover the
   common cases. `update_scene(elements:)` is the raw-Excalidraw
   escape hatch. `read_scene()` returns the current state. No
   `read_canvas_image()`.
6. **Each agent edit lands as a `ChatMessage` row (tool_use
   kind).** Operator sees `draw_shape: rectangle at (100, 200)
   labeled "AuthService"` as a collapsible card in the chat
   transcript next to the actual rendered shape on the canvas.
   Spatial context + conversational context preserved.
7. **Animate agent edits one-by-one.** Each `draw_*` tool call
   is its own DB update + Turbo broadcast cycle, so the operator
   watches shapes pop into the canvas as the agent's reasoning
   produces them. Compelling to watch + reinforces the agent's
   train of thought.
8. **Sync `elements` only, not full `appState`.** Excalidraw's
   `appState` carries viewport position, selection, zoom, theme
   — all per-browser. The DB stores just the elements array;
   each user's appState stays client-side.
9. **Element IDs use Excalidraw's random-string scheme.** Agent
   generates IDs server-side with the same format Excalidraw
   uses client-side so user-created and agent-created elements
   coexist without collisions.
10. **Arrows use `boundElements` + `endBinding`.** `draw_arrow`
    populates both fields so the arrow follows its endpoints
    when the operator moves the underlying shapes. Same
    "stick to shape" UX the operator gets from Excalidraw's
    native tools.
11. **Lazy-load the Excalidraw bundle.** It's ~500 KB–1 MB. Don't
    ship on the initial chat page load; load it when the canvas
    pane becomes visible. Mobile's tab-strip UX handles this
    naturally; the desktop "Hide canvas" toggle does too.
12. **Default layout: 60% canvas / 40% chat with a drag-resize
    handle.** Mobile (<sm): tab-strip — Chat / Canvas tabs at
    the top, same data, single pane at a time.
13. **Per-user "Hide canvas" toggle** in the chat header for
    sessions that don't need the canvas. Persists per-user UI
    state (localStorage); the whiteboard row stays in the DB.

## Components

### 1. Data model

```ruby
# db/migrate/<ts>_create_whiteboards.rb
create_table :whiteboards do |t|
  t.references :chat_session, null: false, foreign_key: true, index: { unique: true }
  t.json :scene_json, null: false, default: { elements: [] }
  t.integer :version, null: false, default: 0     # monotonic; bumped on every save
  t.datetime :last_edited_at
  t.timestamps
end
```

One row per ChatSession (`unique: true` on the FK). Created
lazily — first edit (from either party) writes the row. The
`version` column lets the client detect drift on reconnect
(client says "I have version 14"; server says "current is 17,
here's the new state"; client re-syncs).

`ChatSession`:

- `has_one :whiteboard, dependent: :destroy`

### 2. Excalidraw embed (frontend)

Add the package, mount the component on the chat page:

- `package.json` — add `@excalidraw/excalidraw`.
- `app/javascript/controllers/whiteboard_controller.js` —
  Stimulus controller that lazy-imports `@excalidraw/excalidraw`
  and mounts the React component into a designated DOM element.
- `app/views/repositories/chats/_whiteboard.html.erb` — the
  outer pane that the Stimulus controller targets.

Controller responsibilities:

- Lazy-import Excalidraw on first visible mount. If the operator
  has the canvas hidden, never import.
- Wire `onChange(elements)` → debounced (500ms) PATCH to the
  whiteboard endpoint with `{ elements, version }`.
- Subscribe to the per-whiteboard Turbo Stream channel; on each
  broadcast, update the Excalidraw instance via its
  programmatic API (`excalidrawAPI.updateScene({ elements: ... })`).
- Suppress the controller's own re-PATCH when the change came
  from a Turbo broadcast (don't echo Server → Client → Server).

Layout:

- Two-pane CSS grid: canvas left (60%) / chat right (40%) on
  ≥sm screens. Drag handle in between adjusts the split.
- <sm: tab strip — Chat / Canvas tabs at the top. The whiteboard
  pane mounts inside the active tab so Excalidraw isn't
  hidden via `display: none` (which breaks its sizing).

### 3. Server endpoint for scene updates

`app/controllers/chat_whiteboards_controller.rb`:

- `PATCH /chats/:chat_id/whiteboard` —
  body is `{ elements: [...], expected_version: 14 }`. The
  controller:
  1. Loads the whiteboard (creates one if absent).
  2. If `expected_version != whiteboard.version`, returns
     `409 Conflict` with the current state — client re-syncs.
  3. Otherwise replaces `scene_json["elements"]`, increments
     `version`, updates `last_edited_at`, broadcasts.

Broadcast target: `chat_session_#{chat.id}_whiteboard`. Payload:
the new elements + version.

### 4. Chat sidecar — canvas tools

Add 8 new tools to the chat sidecar from per-repo-chat #273 +
#275. Same Ruby-tool-per-file layout under
`app/services/syrus_chat_mcp/`:

| Tool | Behavior |
|---|---|
| `read_scene()` | Returns the current elements array + version. Cheap; no rasterization. |
| `draw_shape(type, x, y, width, height, label?, color?)` | `type` ∈ `rectangle | ellipse | diamond | sticky`. Creates an Excalidraw element with a fresh ID, server-side append + broadcast. Returns the new element's `id`. |
| `draw_text(content, x, y, font_size?)` | Creates a text element. Returns the id. |
| `draw_arrow(from_id, to_id, label?)` | Creates an arrow with `startBinding`/`endBinding` populated so it sticks to the referenced shapes. Returns the id. |
| `move_element(id, x, y)` | Updates one element's position. Broadcasts. |
| `delete_element(id)` | Removes one element. Broadcasts. |
| `clear_canvas()` | Empties the elements array. Broadcasts. |
| `update_scene(elements)` | Raw escape hatch — replaces the entire elements array. Use sparingly; the high-level tools should cover almost everything. |

Implementation pattern for all writing tools:

1. Acquire a short row-level lock on the whiteboard.
2. Apply the mutation to `whiteboard.scene_json["elements"]`.
3. `whiteboard.version += 1`.
4. Save.
5. Broadcast the update via Turbo Streams.
6. Release.
7. Also write a `ChatMessage` row with `role: "tool_use"`,
   `tool_name: "draw_shape"` (or whatever), `content` =
   structured args. Standard per-repo-chat broadcast path picks
   it up and renders the card next to the canvas.

### 5. ID generation

Excalidraw's element ID is a random base-62 string ~21 chars.
Add a small helper:

```ruby
# app/services/syrus_chat_mcp/excalidraw_id.rb
module SyrusChatMcp
  module ExcalidrawId
    ALPHABET = ("0".."9").to_a + ("A".."Z").to_a + ("a".."z").to_a + %w[_ -]
    def self.generate
      Array.new(21) { ALPHABET.sample(random: SecureRandom) }.join
    end
  end
end
```

Format matches what Excalidraw uses client-side (nanoid). No
collision concerns at our scale.

### 6. Hide-canvas toggle

Small toggle in the chat header — "Show canvas" / "Hide canvas".
Stored in localStorage (`syrus.chat.canvas.<chat_session_id> = hidden`)
so it sticks per browser without DB churn. Server isn't aware;
the layout is pure client-side CSS.

When hidden, the chat pane expands to full width. The whiteboard
row in the DB is untouched; the agent can still mutate it (and
the next time the operator unhides the canvas, the agent's
shapes are there).

## Files to create / modify

**New:**

- `db/migrate/<ts>_create_whiteboards.rb`
- `app/models/whiteboard.rb`
- `app/controllers/chat_whiteboards_controller.rb`
- `app/views/repositories/chats/_whiteboard.html.erb` (canvas pane)
- `app/javascript/controllers/whiteboard_controller.js`
- `app/services/syrus_chat_mcp/excalidraw_id.rb`
- `app/services/syrus_chat_mcp/read_scene_tool.rb`
- `app/services/syrus_chat_mcp/draw_shape_tool.rb`
- `app/services/syrus_chat_mcp/draw_text_tool.rb`
- `app/services/syrus_chat_mcp/draw_arrow_tool.rb`
- `app/services/syrus_chat_mcp/move_element_tool.rb`
- `app/services/syrus_chat_mcp/delete_element_tool.rb`
- `app/services/syrus_chat_mcp/clear_canvas_tool.rb`
- `app/services/syrus_chat_mcp/update_scene_tool.rb`
- Specs for the model + controller + each tool + JS controller.
- Add `@excalidraw/excalidraw` to `package.json`.

**Modified:**

- `app/models/chat_session.rb` — `has_one :whiteboard, dependent: :destroy`
- `app/views/repositories/chats/show.html.erb` — two-pane layout, mount the whiteboard partial, show-canvas toggle.
- `app/javascript/controllers/chat_controller.js` — coordinate with the whiteboard controller (e.g. mobile tab switching).
- `app/services/syrus_chat_mcp/sidecar.rb` — register the 8 new tools.
- `config/routes.rb` — `PATCH/GET /chats/:chat_id/whiteboard`.
- `app/services/prompts/chat_system.rb` — add a paragraph about the whiteboard's existence + when to use the canvas vs prose.

## Build order

Three PRs:

1. **Whiteboard model + Excalidraw embed + user editing.** Schema,
   Whiteboard model, controller endpoint, Excalidraw component
   mounted via Stimulus, two-pane layout + mobile tab-strip,
   drag-resize handle, lazy-load behavior, Turbo broadcast for
   user-driven changes. No MCP integration yet — operator can
   draw, agent is unaware.
2. **MCP canvas sidecar tools — high-level vocab + raw + read.**
   8 tools, ID helper, ChatMessage tool_use rows for each agent
   mutation, live one-by-one shape arrival on the operator's
   canvas. End-to-end test: agent draws a 5-shape diagram in
   one turn → operator sees each appear → operator drags one →
   the change persists. Update the chat system prompt to
   mention the canvas affordance.
3. **Polish — hide-canvas toggle + element-count quota +
   empty-state handling.** Per-user toggle, sensible quota
   (e.g. 1000 elements per whiteboard) with a polite tool-error
   when exceeded, empty-canvas placeholder text.

## Verification

1. **Unit:** model spec for Whiteboard, controller request spec
   for PATCH including version-conflict path, each MCP tool spec
   with stubbed DB.
2. **Operator drawing on `syrus-test`:** open a chat, draw a few
   shapes, refresh the page — shapes persist. Open the same
   chat in two browsers — drag in one, see the change appear
   in the other within ~1s.
3. **Agent drawing on `syrus-test`:** prompt the agent to "draw
   a simple auth flow — user, app server, auth provider, DB —
   with arrows between them." Confirm:
   - Each shape appears one-by-one on the canvas.
   - Each `draw_shape` lands as a `tool_use` ChatMessage card
     in the chat transcript.
   - Arrows stay attached when the operator drags the underlying
     shapes (boundElements wired correctly).
4. **Conflict handling:** open a chat in two browsers, draw
   simultaneously on the same element — last writer wins, no
   data corruption. Version-conflict 409 returned to the loser
   triggers a clean re-sync.
5. **Bundle size:** verify the chat page doesn't load the
   Excalidraw bundle until the canvas pane mounts (DevTools
   Network tab).
6. **Mobile:** open the chat on a phone — Chat tab is the
   default, Canvas tab loads Excalidraw lazily, swiping between
   keeps data consistent.

## Deferred (explicitly not in scope for this plan)

These are real ideas, just postponed to keep v1 shippable:

- **`read_canvas_image()` + server-side PNG rendering.** Skipped
  for v1 — agent reads JSON only. Revisit when M3 of the dev-env
  roadmap brings Playwright/headless Chromium for browser
  testing; Excalidraw's `exportToBlob` API can be invoked from
  a Playwright session against a tiny renderer page. Add the
  tool as a follow-up once Playwright is already deployed.
- **PNG/SVG export attached to proposals.** "Agent drafts an
  architecture proposal and the body includes the rendered
  diagram." Requires server-side render (see above) plus
  proposal-body image support. Both deferred.
- **Real-time CRDT collaboration.** If last-writer-wins proves
  painful (e.g. multi-user adoption in team support — roadmap
  M8), revisit with Yjs or similar. For single-operator v1, LWW
  is fine.
- **Element-level access control.** "User can mark these shapes
  read-only so the agent can't move them" — useful for shared
  artifacts but not for v1.
- **Templates / starter scenes.** "Insert sequence-diagram
  template", "insert system-context-diagram template." Easy to
  add later as predefined scene_json blobs.

## Things to flag, not blockers

- **Excalidraw is React, Syrus is Rails.** The package ships an
  importmap-friendly bundle, but mounting React inside a
  Stimulus controller is a slight architectural seam. Already
  acceptable in the codebase if any other React-on-Rails
  component exists; if not, document the boundary clearly so
  future contributors know where the React island starts and
  ends.
- **Tool-use spam in the transcript** when the agent draws 30
  shapes. Each becomes a ChatMessage card. The cards are
  collapsible by default for noise tools (per the chat plan's
  rendering rule); apply the same default-collapsed treatment
  to the `draw_*` family. The first card per tool kind stays
  expanded so the operator sees what kind of activity is
  happening; subsequent cards collapse.
- **Mobile drag handle UX.** The drag-resize between panes is
  desktop-only by definition. Mobile uses the tab-strip; don't
  try to make resizing work on touch.
- **Bundle vs progressive enhancement.** Operators on slow
  connections shouldn't have the chat unusable until Excalidraw
  loads. Chat works fully before Excalidraw is loaded; the
  canvas pane shows a spinner that swaps to the embed when the
  module is ready.
- **Concurrent agent calls.** If a user message triggers the
  agent to make 20 tool calls, each is a separate DB
  transaction. That's a lot of `whiteboard.save!` + broadcast.
  Acceptable; if perf becomes an issue, batch on the sidecar
  side (debounce broadcasts to ≤ 10/sec).
- **Excalidraw version pinning.** Their JSON schema is stable
  but their npm versions occasionally break compat. Pin the
  major version, document the upgrade-test recipe (load a saved
  scene, confirm it renders).
