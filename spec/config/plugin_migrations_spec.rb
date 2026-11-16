require "rails_helper"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "Plugin migration paths" do
  it "loads bundled plugin migrations through the primary database migration path" do
    # Any bundled plugin that ships migrations proves the wiring; naming one
    # would make that plugin undeletable.
    plugin_migration_dirs = PluginRoots.default.migration_directories.map(&:to_s)

    expect(plugin_migration_dirs).not_to be_empty, "no bundled plugin ships migrations; this spec has nothing to prove"
    expect(Rails.application.paths["db/migrate"].to_a).to include(*plugin_migration_dirs)
    expect(ActiveRecord::Migrator.migrations_paths).to include(*plugin_migration_dirs)
  end

  it "loads an external plugin migration into the Rails migration paths" do
    Dir.mktmpdir("external-plugin-migrations") do |external|
      migration_dir = Pathname.new(external).join("weather/db/migrate").tap(&:mkpath).to_s
      environment = Rails.root.join("config/environment").to_s
      probe = <<~'RUBY'
        require ARGV.fetch(0)
        migration_dir = ARGV.fetch(1)
        configured = Rails.application.paths["db/migrate"].to_a.include?(migration_dir)
        active_record = ActiveRecord::Migrator.migrations_paths.include?(migration_dir)
        abort "external migration path was not configured" unless configured && active_record
      RUBY

      _stdout, stderr, status = Open3.capture3(
        { "RAILS_ENV" => "test", "SYRUS_PLUGIN_PATH" => external },
        RbConfig.ruby,
        "-e",
        probe,
        environment,
        migration_dir,
        chdir: Rails.root.to_s
      )

      expect(status).to be_success, stderr
    end
  end
end
