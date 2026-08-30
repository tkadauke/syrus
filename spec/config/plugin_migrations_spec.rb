require "rails_helper"

RSpec.describe "Plugin migration paths" do
  it "loads bundled plugin migrations through the primary database migration path" do
    design_docs_migrations = Rails.root.join("plugins/design_docs/db/migrate").to_s

    expect(Rails.application.paths["db/migrate"].to_a).to include(design_docs_migrations)
    expect(ActiveRecord::Migrator.migrations_paths).to include(design_docs_migrations)
  end
end
