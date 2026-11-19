require "rails_helper"
require "open3"

RSpec.describe "Plugin migration paths" do
  it "loads bundled plugin migrations through the primary database migration path" do
    # Any bundled plugin that ships migrations proves the wiring; naming one
    # would make that plugin undeletable.
    plugin_migration_dirs = Rails.root.glob("plugins/*/db/migrate").select(&:directory?).map(&:to_s)

    expect(plugin_migration_dirs).not_to be_empty, "no bundled plugin ships migrations; this spec has nothing to prove"
    expect(Rails.application.paths["db/migrate"].to_a).to include(*plugin_migration_dirs)
    expect(ActiveRecord::Migrator.migrations_paths).to include(*plugin_migration_dirs)
  end

  it "discovers migrations from an external plugin root" do
    Dir.mktmpdir do |directory|
      migration_dir = Pathname.new(directory).join("weather/db/migrate")
      migration_dir.mkpath
      stdout, stderr, status = Open3.capture3(
        { "SYRUS_PLUGIN_PATH" => directory, "RAILS_ENV" => "test" },
        Rails.root.join("bin/rails").to_s,
        "runner",
        "puts ActiveRecord::Migrator.migrations_paths"
      )

      expect(status).to be_success, stderr
      expect(stdout.lines.map(&:strip)).to include(migration_dir.to_s)
    end
  end

  it "applies a synced plugin migration through db:prepare and clears the worker boot gate" do
    Dir.mktmpdir do |directory|
      data_root = Pathname.new(directory).join("data")
      plugin_root = data_root.join("plugin-sync/current")
      migration_dir = plugin_root.join("synced_probe/db/migrate").tap(&:mkpath)
      migration_dir.join("20200101000000_create_synced_plugin_probes.rb").write(<<~RUBY)
        class CreateSyncedPluginProbes < ActiveRecord::Migration[8.1]
          def change
            create_table :synced_plugin_probes, if_not_exists: true
          end
        end
      RUBY
      database = Pathname.new(directory).join("migration.sqlite3")
      env = { "SYRUS_DATA_ROOT" => data_root.to_s, "RAILS_ENV" => "test", "SKIP_SCHEMA_DUMP" => "1",
              "DATABASE_URL" => "sqlite3:#{database}" }

      _stdout, _stderr, pending = Open3.capture3(env, Rails.root.join("bin/rails").to_s, "db:abort_if_pending_migrations")
      expect(pending).not_to be_success

      _stdout, stderr, prepared = Open3.capture3(env, Rails.root.join("bin/rails").to_s, "db:prepare")
      expect(prepared).to be_success, stderr

      stdout, stderr, checked = Open3.capture3(env, Rails.root.join("bin/rails").to_s, "runner",
        "puts ActiveRecord::Base.connection.table_exists?(:synced_plugin_probes)")
      expect(checked).to be_success, stderr
      expect(stdout).to include("true")
      expect(Open3.capture3(env, Rails.root.join("bin/rails").to_s, "db:abort_if_pending_migrations").last).to be_success
    end
  end
end
