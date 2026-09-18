import type { ArtifactRendererDefinition, ArtifactRendererExample } from "@app/pluginArtifactRenderers"
import type { MigrationDiffPayload } from "@app/api/artifacts"
import { MigrationDiffRenderer } from "../components/artifacts/MigrationDiffRenderer"

// Registers the `migration_diff` renderer_type by directory convention (see
// pluginArtifactRenderers.tsx) instead of being hardcoded into core's
// pluginArtifactRenderers.tsx -- moving/renaming this file is all it takes
// to change how this plugin's artifact renderer is discovered.
const definition: ArtifactRendererDefinition = {
  rendererType: "migration_diff",
  artifactTypes: [ "rails_migration_diff" ],
  displayLabel: "Rails migration diff",
  description: "Renders a Rails migration as a two-column before/after column table plus a change summary.",
  supportedPayloadShape: "{ migration_name, before: { table_name, columns }, after: { table_name, columns }, changes?: Array<{ type, column }> }",
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
        before: { table_name: "users", columns: [ { name: "id", type: "integer" }, { name: "legacy_key", type: "string" } ] },
        after: { table_name: "users", columns: [ { name: "id", type: "integer" }, { name: "email", type: "string" } ] },
        changes: [
          { type: "removed", column: { name: "legacy_key", type: "string" } },
          { type: "added", column: { name: "email", type: "string" } }
        ]
      }
    }
  }
]

export default definition
