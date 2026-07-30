# Typed Artifacts

Agents can store structured, typed artifacts on a Workflow during a run using the `submit_artifact` MCP tool. Artifacts are persisted under the `'typed_artifacts'` key in `Workflow#artifacts` and survive for the lifetime of the workflow record.

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

## MCP tool: `submit_artifact`

Available to all non-adversarial workflow roles (implement, summary_test_plan, rebase_conflict, manual).

| Parameter | Type   | Required | Description                                  |
|-----------|--------|----------|----------------------------------------------|
| `type`    | string | yes      | Artifact type identifier (non-empty)         |
| `title`   | string | yes      | Human-readable title (non-empty)             |
| `payload` | object | yes      | Artifact data as a JSON object               |

The tool validates that `type` and `title` are non-empty and that `payload` is a JSON object. It does not validate the `type` against a registry — unsupported types are stored and ignored by the UI until a renderer is declared for them.

## Adding a new artifact type

To make a typed artifact renderable in the Syrus job detail UI, a plugin must:

1. Register an `:artifact_renderer` extension that maps the artifact `type` to one of the core renderer types (`erd_diagram`, `migration_diff`, `data_table`, `before_after_diff`).
2. Optionally register a `:prompt_injector` to instruct the implementing agent when to call `submit_artifact`.

See `config/syrus_docs/` for the plugin extension point documentation (forthcoming in EPIC-193).
