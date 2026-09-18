import type { ArtifactRendererDefinition, ArtifactRendererExample } from "@app/pluginArtifactRenderers"
import type { SchemaErdPayload } from "@app/api/artifacts"
import { ErdDiagramRenderer } from "../components/artifacts/ErdDiagramRenderer"

// Registers the `erd_diagram` renderer_type by directory convention (see
// pluginArtifactRenderers.tsx) instead of being hardcoded into core's
// pluginArtifactRenderers.tsx -- moving/renaming this file is all it takes
// to change how this plugin's artifact renderer is discovered.
const definition: ArtifactRendererDefinition = {
  rendererType: "erd_diagram",
  artifactTypes: [ "rails_schema_erd" ],
  displayLabel: "Rails schema ERD",
  description: "Renders a Rails schema as one box per table, with columns, indexes, and foreign keys.",
  supportedPayloadShape: "{ tables: Array<{ name, columns, indexes?, foreign_keys? }> }",
  render: (artifact) => <ErdDiagramRenderer payload={artifact.payload as SchemaErdPayload} />
}

export const examples: ArtifactRendererExample[] = [
  {
    id: "users_and_accounts",
    label: "users + accounts schema",
    artifact: {
      type: "rails_schema_erd",
      title: "Schema ERD",
      created_at: "2026-09-01T12:00:00Z",
      renderer_type: "erd_diagram",
      payload: {
        tables: [
          {
            name: "accounts",
            columns: [ { name: "id", type: "integer" }, { name: "name", type: "string" } ]
          },
          {
            name: "users",
            columns: [ { name: "id", type: "integer" }, { name: "email", type: "string" }, { name: "account_id", type: "integer" } ],
            indexes: [ { name: "index_users_on_email", columns: [ "email" ], unique: true } ],
            foreign_keys: [ { from_column: "account_id", to_table: "accounts", to_column: "id" } ]
          }
        ]
      }
    }
  }
]

export default definition
