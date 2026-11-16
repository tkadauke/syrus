require "rails_helper"

RSpec.describe "plugin frontend contribution registry" do
  it "keeps build-time glob discovery out of migrated contribution consumers" do
    consumers = %w[
      app/frontend/pluginWorkspaceTabs.tsx
      app/frontend/pluginAdminPages.tsx
      app/frontend/pluginSidebarPages.tsx
    ]

    offenders = consumers.select { |path| File.read(Rails.root.join(path)).include?("import.meta.glob") }

    expect(offenders).to be_empty, <<~MESSAGE
      Migrated plugin contribution consumers must read the shared runtime registry,
      not discover build-time modules directly: #{offenders.join(", ")}
    MESSAGE
  end
end
