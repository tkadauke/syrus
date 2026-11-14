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
