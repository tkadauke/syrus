# Typed Artifacts

Workflow agents submit structured review output with
`submit_artifact(type:, title:, payload:)`. Repeating a type replaces its prior
entry. `type` is a free-form, conventionally namespaced identifier; `title` is
the reviewer-facing label and `payload` is JSON.

`submit_visual_artifact(type:, title:, image_base64:, content_type:, source:)`
submits a PNG, JPEG, or WebP image, up to 10 MB decoded. Repeating the type
replaces the prior visual artifact. Browser captures may include page and
viewport metadata.

`list_artifacts(workflow_id:)` lists visual artifacts for a Workflow.
`read_artifact(workflow_id:, type:)` returns the stored image as an MCP image
content block; it applies only to artifacts submitted with
`submit_visual_artifact`. Chat agents may also use `submit_artifact`, with the
same validation and replace-on-type semantics, for chat-scoped artifacts.

The Job detail **Review** tab renders recognized artifact types and falls back
for unknown types. `visual_review_screenshot` payloads describe the captured
page, viewport, source, and image URL. `visual_diff_comparison` payloads pair a
baseline and current capture with comparison metadata for before/after review.

Storage, payload-enrichment, and frontend Media-panel internals live in [typed
artifact architecture](../../docs/engineering/architecture/typed-artifacts.md).
Plugin renderers are documented in the [plugin authoring
reference](../../docs/engineering/conventions/plugins/authoring.md); Rails
schema and migration artifacts are owned by the [Rails plugin](../../plugins/rails/docs/syrus_docs/rails.md).
## MCP tool: `submit_artifact` (workflow surface)

Available to all non-adversarial workflow roles (implement, summary_test_plan, rebase_conflict, manual).

| Parameter | Type   | Required | Description                                  |
|-----------|--------|----------|----------------------------------------------|
| `type`    | string | yes      | Artifact type identifier (non-empty)         |
| `title`   | string | yes      | Human-readable title (non-empty)             |
| `payload` | object | yes      | Artifact data as a JSON object               |

The tool validates that `type` and `title` are non-empty and that `payload` is a JSON object. It does not validate the `type` against a registry — unsupported types are stored and ignored by the UI until a renderer is declared for them.

## MCP tool: `submit_visual_artifact` (workflow surface)

Image-capable sibling of `submit_artifact`, for screenshots and other images. Same role availability (implement, summary_test_plan, rebase_conflict, manual). For visual review screenshots, prefer `capture_current_browser: true` so Syrus captures from the current authenticated MCP browser session and stamps page provenance. Omitting `capture_current_browser`, `image_path`, and `image_base64` also captures the current browser, preserving compatibility with agents that have an older cached tool schema. Use `image_path` when the image already exists in the workflow workspace; use `image_base64` only when the bytes are already in memory.

| Parameter                 | Type    | Required | Description                                                          |
|---------------------------|---------|----------|------------------------------------------------------------------------|
| `type`                    | string  | yes      | Artifact type identifier (non-empty)                                  |
| `title`                   | string  | yes      | Human-readable title (non-empty)                                      |
| `capture_current_browser` | boolean | no       | Capture the current authenticated MCP browser page directly; this is also the default when all image inputs are omitted |
| `subject`                 | object  | no       | Structured snapshot-ref, CSS, or semantic accessibility target to center before a current-browser capture |
| `image_path`              | string  | no       | Path to an image file inside the workflow workspace, relative to the workspace root or absolute within it |
| `image_base64`            | string  | no       | Base64-encoded image bytes, no `data:` URI prefix                     |
| `content_type`            | string  | no       | One of `image/png`, `image/jpeg`, `image/webp`. Defaults from the captured image, from `image_path` extension, or to `image/png` |

Provide at most one of `capture_current_browser`, `image_path`, or `image_base64`; omitting all three captures the current browser. Agent-supplied file paths are resolved inside the workflow workspace and rejected if they point outside it.

For current-browser captures, `subject` accepts `{type: "css", selector: "..."}`,
`{type: "semantic", role: "...", name: "..."}`, or `{type: "snapshot_ref",
ref: "e12", snapshot_token: "..."}`. `browser_snapshot` returns the freshness
token. Navigation, state-changing browser actions, and viewport changes
invalidate it; stale refs fail with a retryable `stale_snapshot_ref` structured
error. Ambiguous bare words such as `complementary` are rejected before browser
evaluation with guidance to choose semantic or CSS targeting. Syrus waits for
the optional `subject` to become
visible, centers it in the viewport, allows the page to settle briefly, and
then captures the viewport. Omitting `subject` preserves the current scroll
position.

Unlike `submit_artifact`, the image bytes are not stored in the Workflow artifact value. They are decoded and attached to the Workflow via ActiveStorage (`Workflow#visual_artifacts`, a `has_many_attached` mirroring the existing `coverage_hit_map` pattern), capped at 10 MB decoded. The `typed_artifacts` entry's `payload` instead carries `content_type`, `byte_size`, `source`, `captured_at`, and an `image_url` the UI fetches the bytes from (`GET /api/v1/app/workflows/:workflow_id/visual_artifact?type=<type>`). Current-browser captures also include `page` (`url`, `path`, `title`) and `viewport` (`width`, `height`, `device_scale_factor`) when the browser can report them. Calling it again with the same `type` replaces both the entry and the previously stored blob — the old blob is purged, not orphaned.

If the configured ActiveStorage backend is temporarily unreachable while serving that `image_url` (for example a transient MinIO connection refusal in the k3s service path), the app API returns `503` JSON with `error.code = "storage_unavailable"` and a short `Retry-After` header instead of raising a 500. The admin overview includes an "Artifact storage" tile backed by the same ActiveStorage probe so operators can distinguish a storage/backend outage from a broken workflow artifact.

## MCP tools: `list_artifacts` / `read_artifact` (workflow surface)

Read-only companions to `submit_artifact`/`submit_visual_artifact`, for an agent that needs to discover or actually see a previously submitted artifact — the only prior consumer was the human-facing `visual_artifact` HTTP endpoint and its React viewer. Same role availability as `submit_visual_artifact` (implement, summary_test_plan, rebase_conflict, manual, visual_reviewer).

`list_artifacts` takes a `workflow_id` (integer, required) and returns each `typed_artifacts` entry as `{ type, title, content_type, byte_size, run_id, step_id, iteration, image_url, source, captured_at, page, viewport }` — image fields and provenance come from the entry's `payload` and are only populated when they were available at submission time. Use this first to find the `type` key an entry was actually stored under, since `submit_visual_artifact` rewrites the caller-supplied `type` into a run-scoped stored type (e.g. `visual_review_screenshot_run_44_1`).

`read_artifact` takes `workflow_id` and `type` (both required) and returns the stored image (looked up via `Workflow#visual_artifact_for(type)`) as an MCP image content block — the same mechanism `browser_screenshot` already uses to hand an agent real image bytes it can see mid-turn, not a metadata-only echo. It only succeeds for artifacts with an attached ActiveStorage blob (i.e. ones written by `submit_visual_artifact`); a `type` written only by `submit_artifact` has no image to read.

Both tools scope `workflow_id` to the same repository and owning user as the current Run — a `workflow_id` from a different Job's repository, or a nonexistent id, is rejected with "workflow_id is outside this repository scope" rather than resolved.

## MCP tools: `list_artifacts` / `read_artifact` (chat surface)

Chat-surface counterparts, available to chat agents. Same input/output shape as the workflow-surface tools above, but `workflow_id` is authorized via the same ownership scoping every other chat workflow-inspection tool uses (`read_workflow`, `read_run_transcript`): any Workflow belonging to a Job in a repository owned by the chat session's user, regardless of which repository the chat session itself is attached to.

## MCP tool: `submit_artifact` (chat surface)

Available to chat agents (planning, coding, and local-mode sessions). Same parameters, validation, and replace-on-type idempotency as the workflow-surface tool above, but it writes into `ChatSession#artifacts["typed_artifacts"]` instead of `Workflow#artifacts["typed_artifacts"]` — there is no Workflow or Run in a chat session. A chat agent asked to visualize the schema or explain a migration can call `read_schema`/`explain_migration`-style repository tooling and then `submit_artifact` to hand the operator a rendered result in the chat.

## Chat Media library

Typed artifacts submitted in a chat session appear in `GET /api/v1/app/chats/:id/media` as a paginated `typed_artifacts` array, alongside the existing `snapshots` (whiteboard) and paginated `chat_images` keys. The listing omits artifact payload bodies; the panel fetches one body from `GET /api/v1/app/chats/:id/media/typed_artifacts/:artifact_type` only when the operator opens it. Each entry is enriched with `renderer_type` the same way the job detail payload is, via the shared `TypedArtifactRenderer.enrich` service — a plugin only needs to register its `:artifact_renderer` once to render on both surfaces.

The chat workspace's **Media** panel lists these under an "Artifacts" section alongside whiteboard snapshots and variant-capable image attachments, showing each artifact's title, type, and submission time. Each collection has its own load-more control. Image tiles use bounded thumbnails; non-variable formats such as SVG are omitted from the grid rather than served at full size through the thumbnail route. Opening, downloading, or attaching a listed image fetches its full-size chat-scoped file URL. Clicking "View" lazily loads and renders the artifact inline using the same renderer used by Job Review and Report surfaces, so a plugin-provided artifact renderer behaves consistently without chat-specific setup.

## Adding a new artifact type

To make a typed artifact renderable in the Syrus job detail UI, a plugin must:

1. Register an `:artifact_renderer` extension that maps the artifact `type` to one of the core renderer types (`erd_diagram`, `migration_diff`, `data_table`, `before_after_diff`, `image_diff`).
2. Optionally register a `:prompt_injector` to instruct the implementing agent when to call `submit_artifact` (or `submit_visual_artifact`, for images).

See `config/syrus_docs/plugins.md` for the full `:artifact_renderer` extension point API.

Artifact renderers are registered by plugins in their `provides:` hash:

```ruby
Syrus::PluginRegistry.register(
  name:    "syrus-rails",
  version: "0.1.0",
  provides: {
    artifact_renderer: [
      SyrusRails::SchemaErdRenderer,   # type: 'rails_schema_erd'  → renderer: 'erd_diagram'
      SyrusRails::MigrationDiffRenderer # type: 'rails_migration_diff' → renderer: 'migration_diff'
    ]
  }
)
```

Artifacts whose type is not registered by any plugin pass through without a `renderer_type` and fall back to a JSON code block in the UI.

## Job detail artifact rendering

The job detail page renders typed artifacts in contextual surfaces rather than a standalone tab. The **Review** tab shows review-supporting artifacts in its "Review artifacts" panel, and investigation **Report** views render explicitly referenced artifacts inline with the submitted report. Each artifact is rendered based on its `renderer_type`:

| `renderer_type` | Display |
|---|---|
| `erd_diagram` | Table boxes with column lists and foreign key arrows |
| `migration_diff` | Two-column before/after table schema diff (added columns highlighted) |
| `data_table` | HTML table from `headers` and `rows` arrays in the payload |
| `before_after_diff` | Side-by-side before/after `<pre>` blocks |
| `image_diff` | Single `<img>`, linked to the full-size image (after-only; no before/after comparison yet) |
| `null` (no registered renderer) | Raw JSON display |

Every typed artifact entry from every artifact-bearing workflow on the job is returned — same-type entries from different workflows (e.g. successive visual/adversarial review rounds, or a schema ERD resubmitted on a later `pr_comment` workflow) are **not** collapsed to the most recent one; each is tagged with the provenance fields described above so the UI can group, label, and filter them by diff review version instead of silently dropping older rounds.

On the Job detail **Review** tab, the "Review artifacts" panel additionally filters this list against the selected diff review version/range: an artifact whose `diff_review_version_id` or `head_sha` matches the selection is shown; one tied to a different version is hidden; one with no provenance at all is always shown, labeled "Unversioned" rather than silently hidden or misattributed to whatever version happens to be selected. Matching is exact only (`diff_review_version_id` first, then `head_sha`) — no ancestry/range-containment inference.

## syrus_rails plugin artifact types

### `rails_schema_erd`

Rendered as an entity-relationship diagram (`:erd_diagram` renderer). Payload produced by the `read_schema` MCP tool:

```json
{
  "tables": [
    {
      "name": "users",
      "columns": [{ "name": "id", "type": "integer" }, ...],
      "indexes": [{ "name": "index_users_on_email", "columns": ["email"], "unique": true }],
      "foreign_keys": [{ "from_column": "account_id", "to_table": "accounts", "to_column": "id" }]
    }
  ]
}
```

### `rails_migration_diff`

Rendered as a before/after database-catalog diff (`:migration_diff` renderer). `explain_migration`
loads the workflow base schema into a uniquely named disposable database, applies all newly added
migrations in timestamp order, and snapshots the catalog through Active Record around each one.
Server-backed adapters require a local-only `SYRUS_RAILS_ARTIFACT_DATABASE_URL`; when disposable
database creation is unavailable, the tool clearly labels a cumulative base/head schema-dump diff.
All named development database configurations are redirected to separately named sandboxes before the app boots.
Both `schema.rb` and adapter-native `structure.sql` baselines are supported.
Data-only migrations use `no_schema_changes`, and setup, execution, introspection, or cleanup
failures use `error` rather than an empty successful-looking diff.

Current payloads contain normalized `tables` catalogs (columns and type parameters, indexes,
foreign keys, and supported check constraints):

```json
{
  "migration_name": "AddEmailToUsers",
  "status": "success",
  "before": { "tables": [...] },
  "after":  { "tables": [...] }
}
```

The renderer continues to accept the legacy single-table `before`/`after` plus `changes` shape for
artifacts stored by older workflows.

## browser plugin artifact types

### Visual-review screenshots

The preferred generic type is `visual_review_screenshot`, but callers may use
descriptive types such as `visual_review_desktop_bulk_progress`. They are
rendered as single after screenshots (`:image_diff` renderer). Visual-review
browser captures are first stored as drafts and return a stable evidence ID.
Pass that ID as `captured_evidence_id` to curate the existing image without a
second capture; the direct browser, file, and base64 paths remain supported.
iteration association uses trusted same-Run provenance and image metadata,
not an exact original type. Payload written by `submit_visual_artifact`:

```json
{
  "content_type": "image/png",
  "byte_size": 48213,
  "source": "current_browser",
  "captured_at": "2026-10-08T15:04:05.123Z",
  "image_url": "/api/v1/app/workflows/123/visual_artifact?type=visual_review_screenshot",
  "page": {
    "url": "http://127.0.0.1:3000/credential_store",
    "path": "/credential_store",
    "title": "Credential store"
  },
  "viewport": {
    "width": 1440,
    "height": 900,
    "device_scale_factor": 1
  },
  "subject": { "type": "css", "selector": "[data-testid=credential-list]" },
  "subject_visible_fraction": 1.0,
  "subject_rect": {
    "x": 120,
    "y": 180,
    "width": 960,
    "height": 420
  },
  "scroll_position": {
    "x": 0,
    "y": 640
  }
}
```

When a subject is supplied, capture is rejected unless at least half of its
area is inside the viewport by default. Callers may configure that fraction;
subjects taller than the viewport instead require their top edge to be visible.

### `visual_diff_comparison`

Rendered as a paired before/after visual comparison (`:before_after_visual_diff` renderer). Payload written by the deferred `visual_diff` workflow after it captures merge-base baseline screenshots and pairs them with the PR screenshots from a prior visual-review workflow:

Each pair is displayed in one responsive overlay: PR/head is on the left and
merge-base is on the right. Operators can drag the divider with a pointer or
touch, move it with the keyboard, or tap the frame to open a larger preview
that cycles between the labeled images with buttons, arrow keys, or a swipe.

