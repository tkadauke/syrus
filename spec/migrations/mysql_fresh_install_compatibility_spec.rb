require "rails_helper"

RSpec.describe "MySQL fresh install compatibility", :ci_only do
  let(:migration_paths) { Rails.root.glob("db/migrate/*.rb").sort }
  let(:migration_sources) { migration_paths.to_h { |path| [ path.basename.to_s, path.read ] } }

  it "uses distinct migration class names and filenames" do
    classes = migration_sources.values.flat_map do |source|
      source.scan(/^\s*class\s+([A-Z]\w*)\s+<\s+ActiveRecord::Migration/).flatten
    end
    names = migration_paths.map { |path| path.basename.to_s.sub(/\A\d+_/, "").sub(/\.rb\z/, "") }

    duplicates = classes.concat(names).tally.select { |_name, count| count > 1 }

    expect(duplicates).to be_empty
  end

  it "does not load the SQLite schema dump for production MySQL setup" do
    production_config = Rails.root.join("config/environments/production.rb").read

    # MySQL (the default — SYRUS_SQLITE unset) keeps :sql so fresh installs
    # migrate from zero instead of loading the SQLite schema.rb. Only the
    # single-host SQLite "local mode" opts into :ruby (where schema.rb is
    # exactly right).
    expect(production_config).to include('ENV["SYRUS_SQLITE"].present? ? :ruby : :sql')
  end

  it "adds approved_at before creating the landing queue index" do
    migration = migration_sources.fetch("20260516000000_add_landing_queue_fields.rb")

    approved_at_position = migration.index("add_column :jobs, :approved_at")
    landing_index_position = migration.index("add_index :jobs, [ :state, :approved_at, :id ]")

    expect(approved_at_position).to be < landing_index_position
  end

  it "uses bigint columns for user foreign keys added outside references helpers" do
    expect(migration_sources.fetch("20260602234619_add_owner_to_epics.rb"))
      .to include("add_column :epics, :owner_id, :bigint")
    expect(migration_sources.fetch("20260603012937_add_owner_user_to_jobs.rb"))
      .to include("add_column :jobs, :owner_user_id, :bigint")
    expect(migration_sources.fetch("20260603034657_add_execution_owner_to_workflows_and_runs.rb"))
      .to include("add_column :workflows, :user_id, :bigint")
      .and include("add_column :runs, :user_id, :bigint")
  end

  # Generic guard so the next hand-rolled FK column can't reintroduce the
  # int-vs-bigint mismatch. Rails primary keys are bigint on MySQL; an
  # :integer foreign-key column referencing one fails with
  # MismatchedForeignKey on db:prepare (SQLite silently tolerates it, so
  # dev/test/CI stay green while every MySQL deploy crash-loops the web
  # pod's db-prepare init container).
  it "never adds an :integer foreign-key column" do
    offenders = migration_sources.flat_map do |filename, source|
      add_column_offenders = source.scan(/add_column\s+:\w+,\s+:(\w*_id),\s+:integer/).map { |(column)| column }
      add_reference_offenders = source.scan(/add_reference\s+:\w+,\s+:\w+,[^\n]*type:\s+:integer/).map(&:strip)

      add_column_offenders.concat(add_reference_offenders).map { |column| "#{filename}: #{column}" }
    end

    expect(offenders).to be_empty
  end

  it "does not enforce database-level foreign keys" do
    initializer = Rails.root.join("config/initializers/foreign_keys.rb").read
    schema = Rails.root.join("db/schema.rb").read

    expect(initializer).to include("def add_foreign_key(*)")
    expect(initializer).to include("ActiveRecord::ConnectionAdapters::SchemaStatements.prepend")
    expect(schema).not_to include("add_foreign_key")
  end

  it "does not add new foreign key declarations after the no-FK policy migration" do
    offenders = migration_sources.filter_map do |filename, source|
      next if filename < "20260820010000"

      if source.match?(/add_foreign_key|foreign_key:\s*(true|\{)/)
        filename
      end
    end

    expect(offenders).to be_empty
  end
end
