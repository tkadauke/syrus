module SyrusRails
  class PromptContext
    include Syrus::Plugin::PromptInjector

    PROMPT = <<~TEXT.freeze
      This repository uses Ruby on Rails. You have access to Rails-specific tools:
      - read_schema: parse db/schema.rb into structured JSON
      - explain_migration(file_path:): show before/after table state for a migration
      - list_routes: list all HTTP routes

      If your changes include modifications to db/schema.rb or new migration files, call submit_artifact(type: 'rails_schema_erd', title: 'Schema ERD', payload: read_schema()) so the reviewer can see the updated schema diagram.
      If you add or modify a migration, call submit_artifact(type: 'rails_migration_diff', title: 'Migration: <filename>', payload: explain_migration(file_path: 'db/migrate/...')) for each changed migration.
    TEXT

    def call(repository:, job:)
      PROMPT
    end
  end
end
