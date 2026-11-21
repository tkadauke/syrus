require "rails_helper"

# Every table in db/schema.rb is created by a migration, core or plugin.
#
# A table with no migration exists only because a schema dump copied it from
# a database that still had it -- typically after a migration was edited
# instead of followed by a drop migration. `db:schema:load` then builds it on
# every fresh install, existing databases keep it forever, and
# Syrus::PluginPurge, which reads a plugin's migrations and models to find its
# tables, can never remove it, so "purge removes what the plugin owns" quietly
# stops being true (formal/FINDINGS.md M15).
RSpec.describe "db/schema.rb tables" do
  # Left by an edited migration; whether to drop them is NY16 in
  # formal/coverage/coverage.json. Remove an entry once a migration drops it.
  PENDING_ORPHANS = %w[
    operator_briefing_review_findings
    operator_briefing_workflow_notable_changes
  ].freeze

  def migration_sources
    Dir[Rails.root.join("{db,plugins/*/db}/migrate/*.rb")].map { |path| File.read(path) }
  end

  def created_by_migrations
    migrated = migration_sources.flat_map do |source|
      names = source.scan(/create_table\s*\(?\s*(?::(\w+)|["'](\w+)["'])/).flatten.compact +
        source.scan(/rename_table\s*\(?\s*:\w+\s*,\s*:(\w+)/).flatten +
        source.scan(/CREATE\s+(?:VIRTUAL\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["`]?(\w+)/i).flatten
      # Renames driven by a `{ old: :new }` map.
      names += source.scan(/\b\w+:\s*:(\w+)/).flatten if source.include?("rename_table")
      names
    end
    # Solid Queue, Cache and Cable install their tables from their own schema
    # files; the single test database loads them into schema.rb too.
    engine_schemas = Dir[Rails.root.join("db/{queue,cache,cable}_schema.rb")].flat_map do |path|
      File.read(path).scan(/create_table\s+"(\w+)"/).flatten
    end
    (migrated + engine_schemas).to_set
  end

  def schema_tables
    File.read(Rails.root.join("db/schema.rb")).scan(/^\s*create_table\s+"(\w+)"/).flatten
  end

  it "has a creating migration for every table" do
    orphans = schema_tables.reject { |table| created_by_migrations.include?(table) } - PENDING_ORPHANS

    expect(orphans).to be_empty, "tables in db/schema.rb that no migration creates:\n#{orphans.join("\n")}"
  end

  it "keeps the pending orphan list honest" do
    expect(PENDING_ORPHANS - schema_tables).to be_empty
    expect(PENDING_ORPHANS.select { |table| created_by_migrations.include?(table) }).to be_empty
  end
end
