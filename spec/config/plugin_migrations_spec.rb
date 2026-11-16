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
end
