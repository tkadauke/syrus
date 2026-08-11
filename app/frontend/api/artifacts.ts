// Typed artifact types shared by the Job API client (workflow-scoped
// artifacts) and the chat API client (chat-scoped artifacts). Extracted so
// neither client depends on the other.

export type TypedArtifact = {
  type: string
  title: string
  payload: SchemaErdPayload | MigrationDiffPayload | Record<string, unknown>
  created_at: string
  renderer_type: "erd_diagram" | "migration_diff" | "data_table" | "before_after_diff" | null
}

export type ErdColumn = {
  name: string
  type: string
  options?: Record<string, unknown>
}

export type ErdIndex = {
  name: string
  columns: string[]
  unique?: boolean
}

export type ErdForeignKey = {
  from_column: string
  to_table: string
  to_column: string
}

export type ErdTable = {
  name: string
  columns: ErdColumn[]
  indexes?: ErdIndex[]
  foreign_keys?: ErdForeignKey[]
}

export type SchemaErdPayload = {
  tables: ErdTable[]
}

export type MigrationDiffColumn = {
  name: string
  type: string
}

export type MigrationDiffChange = {
  type: "added" | "removed" | "modified"
  column: MigrationDiffColumn
}

export type MigrationDiffPayload = {
  migration_name: string
  before: { table_name: string; columns: MigrationDiffColumn[] }
  after: { table_name: string; columns: MigrationDiffColumn[] }
  changes: MigrationDiffChange[]
}
