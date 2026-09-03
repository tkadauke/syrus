require "rails_helper"

RSpec.describe "Plugin migration paths" do
  it "loads bundled plugin migrations through the primary database migration path" do
    # Any bundled plugin that ships migrations proves the wiring; naming one
    # would make that plugin undeletable.
    plugin_migration_dirs = Rails.root.glob("plugins/*/db/migrate").select(&:directory?).map(&:to_s)

    expect(plugin_migration_dirs).not_to be_empty, "no bundled plugin ships migrations; this spec has nothing to prove"
    expect(Rails.application.paths["db/migrate"].to_a).to include(*plugin_migration_dirs)
    expect(ActiveRecord::Migrator.migrations_paths).to include(*plugin_migration_dirs)
  end
end
