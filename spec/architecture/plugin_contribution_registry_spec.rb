require "rails_helper"

RSpec.describe "plugin frontend contribution registry" do
  MIGRATED_CONSUMERS = %w[
    app/frontend/pluginWorkspaceTabs.tsx
    app/frontend/pluginAdminPages.tsx
    app/frontend/pluginSidebarPages.tsx
  ].freeze

  it "keeps build-time globs out of migrated contribution consumers" do
    offenders = MIGRATED_CONSUMERS.select { |path| Rails.root.join(path).read.include?("import.meta.glob") }

    expect(offenders).to be_empty,
      "migrated consumers must read the shared registry instead of declaring import.meta.glob: #{offenders.join(', ')}"
  end
end
