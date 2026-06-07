require "rails_helper"

RSpec.describe "MySQL fresh install compatibility" do
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

    expect(production_config).to include("config.active_record.schema_format = :sql")
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
  end
end
