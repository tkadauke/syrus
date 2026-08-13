# Typed Artifacts

Agents can store structured, typed artifacts on a Workflow during a run using the `submit_artifact` MCP tool. Artifacts are persisted under the `'typed_artifacts'` key in `Workflow#artifacts` and survive for the lifetime of the workflow record. They appear in the job detail UI with a renderer selected by the plugin registry.

Chat sessions have the same capability: a chat-surface `submit_artifact` MCP tool persists entries under the `'typed_artifacts'` key in `ChatSession#artifacts`, using the identical entry shape and replace-on-type idempotency described below. Both the workflow-surface and chat-surface tools share one `renderer_type` lookup implementation, `TypedArtifactRenderer.enrich`, so a new `:artifact_renderer` plugin registration is picked up on both surfaces automatically. See "Chat Media library" below.

## Convention

Typed artifacts live as an array of entries under `Workflow#artifacts["typed_artifacts"]`. Each entry has this shape:

```json
{
  "type":       "rails_schema_erd",
  "title":      "Schema ERD",
  "payload":    { ... },
  "created_at": "2026-07-29T12:00:00Z"
}
```

- **`type`** — free-form string identifier. Namespaced by convention (e.g. `rails_schema_erd`, `rails_migration_diff`). No registry check at write time; unknown types are stored but not rendered until a renderer is registered.
- **`title`** — human-readable label shown in the UI.
- **`payload`** — arbitrary JSON object; schema is defined by the artifact type and its renderer.
- **`created_at`** — ISO 8601 timestamp set at write time.

Calling `submit_artifact` with the same `type` a second time **replaces** the previous entry. Entries with different types accumulate.

## MCP tool: `submit_artifact` (workflow surface)

Available to all non-adversarial workflow roles (implement, summary_test_plan, rebase_conflict, manual).

| Parameter | Type   | Required | Description                                  |
|-----------|--------|----------|----------------------------------------------|
| `type`    | string | yes      | Artifact type identifier (non-empty)         |
| `title`   | string | yes      | Human-readable title (non-empty)             |
| `payload` | object | yes      | Artifact data as a JSON object               |

The tool validates that `type` and `title` are non-empty and that `payload` is a JSON object. It does not validate the `type` against a registry — unsupported types are stored and ignored by the UI until a renderer is declared for them.

## MCP tool: `submit_visual_artifact` (workflow surface)

Image-capable sibling of `submit_artifact`, for base64-encoded screenshots and other images. Same role availability (implement, summary_test_plan, rebase_conflict, manual).

| Parameter      | Type   | Required | Description                                                          |
|----------------|--------|----------|------------------------------------------------------------------------|
| `type`         | string | yes      | Artifact type identifier (non-empty)                                  |
| `title`        | string | yes      | Human-readable title (non-empty)                                      |
| `image_base64` | string | yes      | Base64-encoded image bytes, no `data:` URI prefix                     |
| `content_type` | string | no       | One of `image/png`, `image/jpeg`, `image/webp`. Defaults to `image/png` |

Unlike `submit_artifact`, the image bytes are not stored in the `Workflow#artifacts` JSON column. They are decoded and attached to the Workflow via ActiveStorage (`Workflow#visual_artifacts`, a `has_many_attached` mirroring the existing `coverage_hit_map` pattern), capped at 10 MB decoded. The `typed_artifacts` entry's `payload` instead carries `content_type`, `byte_size`, and an `image_url` the UI fetches the bytes from (`GET /api/v1/app/workflows/:workflow_id/visual_artifact?type=<type>`). Calling it again with the same `type` replaces both the entry and the previously stored blob — the old blob is purged, not orphaned.

## MCP tool: `submit_artifact` (chat surface)

Available to chat agents (planning, coding, and local-mode sessions). Same parameters, validation, and replace-on-type idempotency as the workflow-surface tool above, but it writes into `ChatSession#artifacts["typed_artifacts"]` instead of `Workflow#artifacts["typed_artifacts"]` — there is no Workflow or Run in a chat session. A chat agent asked to visualize the schema or explain a migration can call `read_schema`/`explain_migration`-style repository tooling and then `submit_artifact` to hand the operator a rendered result in the chat.

## Chat Media library

Typed artifacts submitted in a chat session appear in `GET /api/v1/app/chats/:id/media` as a `typed_artifacts` array, alongside the existing `snapshots` (whiteboard) and `chat_images` keys. Each entry is enriched with `renderer_type` the same way the job detail payload is, via the shared `TypedArtifactRenderer.enrich` service — a plugin only needs to register its `:artifact_renderer` once to render on both surfaces.

The chat workspace's **Media** panel (`app/frontend/routes/chat/WorkspacePanels.tsx`) lists these under an "Artifacts" section alongside whiteboard snapshots and image attachments, showing each artifact's title, type, and submission time. Clicking "View" renders the artifact inline using the same `TypedArtifactPanel` component (`app/frontend/components/artifacts/TypedArtifactPanel.tsx`) the job detail Artifacts tab uses, so a new `:artifact_renderer` plugin renders identically on both surfaces without any chat-specific UI work. The shared `TypedArtifact`/`SchemaErdPayload`/`MigrationDiffPayload` types live in `app/frontend/api/artifacts.ts`, imported by both the Job and chat API clients.

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

## Artifacts panel in job detail

The job detail page shows an **Artifacts** tab listing all typed artifacts for the job. Each artifact is rendered based on its `renderer_type`:

| `renderer_type` | Display |
|---|---|
| `erd_diagram` | Table boxes with column lists and foreign key arrows |
| `migration_diff` | Two-column before/after table schema diff (added columns highlighted) |
| `data_table` | HTML table from `headers` and `rows` arrays in the payload |
| `before_after_diff` | Side-by-side before/after `<pre>` blocks |
| `image_diff` | Single `<img>`, linked to the full-size image (after-only; no before/after comparison yet) |
| `null` (no registered renderer) | Raw JSON display |

Artifacts are deduplicated by `type` across all workflows on the job; the most recently produced entry for each type wins. The tab count reflects the number of unique artifact types present.

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

Rendered as a two-column before/after diff (`:migration_diff` renderer). Payload produced by the `explain_migration` MCP tool:

```json
{
  "migration_name": "AddEmailToUsers",
  "before": { "table_name": "users", "columns": [...] },
  "after":  { "table_name": "users", "columns": [...] },
  "changes": [
    { "type": "added",    "column": { "name": "email",  "type": "string" } },
    { "type": "removed",  "column": { "name": "legacy_key", "type": "string" } },
    { "type": "modified", "column": { "name": "status", "type": "integer" } }
  ]
}
```

## browser plugin artifact types

### `visual_review_screenshot`

Rendered as a single image (`:image_diff` renderer). Payload written by `submit_visual_artifact`:

```json
{
  "content_type": "image/png",
  "byte_size": 48213,
  "image_url": "/api/v1/app/workflows/123/visual_artifact?type=visual_review_screenshot"
}
```
