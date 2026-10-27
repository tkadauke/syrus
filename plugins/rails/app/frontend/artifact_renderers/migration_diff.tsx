import type { ArtifactRendererDefinition, ArtifactRendererExample } from "@app/pluginArtifactRenderers"
import type { MigrationDiffPayload } from "@app/api/artifacts"
import { MigrationDiffRenderer } from "../components/artifacts/MigrationDiffRenderer"

// Registers the `migration_diff` renderer_type by directory convention (see
// pluginArtifactRenderers.tsx) instead of being hardcoded into core's
// pluginArtifactRenderers.tsx -- moving/renaming this file is all it takes
// to change how this plugin's artifact renderer is discovered.
const definition: ArtifactRendererDefinition = {
  rendererType: "migration_diff",
  artifactTypes: ["rails_migration_diff"],
  displayLabel: "Rails migration diff",
  description: "Renders database-backed Rails migration catalogs, explicit outcomes, and cumulative structure.sql fallbacks.",
  supportedPayloadShape:
    "{ migration_name, status?, before: { tables? | structure? }, after: { tables? | structure? }, cumulative?, message? } (legacy table_name/columns/changes also supported)",
  render: (artifact) => <MigrationDiffRenderer payload={artifact.payload as MigrationDiffPayload} />
}

export const examples: ArtifactRendererExample[] = [
  {
    id: "add_email_to_users",
    label: "AddEmailToUsers migration",
    artifact: {
      type: "rails_migration_diff",
      title: "Migration: 20260901010100_add_email_to_users.rb",
      created_at: "2026-09-01T12:00:00Z",
      renderer_type: "migration_diff",
      payload: {
        migration_name: "AddEmailToUsers",
        before: {
          table_name: "users",
          columns: [
            { name: "id", type: "integer" },
            { name: "legacy_key", type: "string" }
          ]
        },
        after: {
          table_name: "users",
          columns: [
            { name: "id", type: "integer" },
            { name: "email", type: "string" }
          ]
        },
        changes: [
          { type: "removed", column: { name: "legacy_key", type: "string" } },
          { type: "added", column: { name: "email", type: "string" } }
        ]
      }
    }
  },
  {
    id: "cumulative_structure_fallback",
    label: "Cumulative structure.sql fallback",
    description: "Exercises the cumulative warning, an empty removed side, and long SQL overflow at narrow viewport widths.",
    artifact: {
      type: "rails_migration_diff",
      title: "Cumulative migration diff",
      created_at: "2026-10-22T12:00:00Z",
      renderer_type: "migration_diff",
      payload: {
        migration_name: "20261022080636_create_workflow_artifact_values",
        status: "cumulative_fallback",
        cumulative: true,
        message: "Cumulative schema diff for 2 migrations; per-migration attribution unavailable because disposable database creation is unavailable.",
        before: { structure: [] },
        after: {
          structure: [
            "CREATE TABLE workflow_artifact_values (id bigint NOT NULL PRIMARY KEY, workflow_id bigint NOT NULL, name character varying(255) NOT NULL, value text, created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL, CONSTRAINT fk_workflow_artifact_values_workflow FOREIGN KEY (workflow_id) REFERENCES workflows(id))",
            "CREATE UNIQUE INDEX index_workflow_artifact_values_on_workflow_id_and_name ON workflow_artifact_values USING btree (workflow_id, name)"
          ]
        }
      }
    }
  }
]

export default definition
