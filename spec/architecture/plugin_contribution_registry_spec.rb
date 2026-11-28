require "rails_helper"

RSpec.describe "plugin frontend contribution registry" do
  MIGRATED_CONSUMERS = %w[
    app/frontend/pluginWorkspaceTabs.tsx
    app/frontend/pluginAdminPages.tsx
    app/frontend/pluginSidebarPages.tsx
    app/frontend/pluginRepoPageTabs.tsx
    app/frontend/pluginSlugPreviewCards.tsx
    app/frontend/pluginReviewContributions.tsx
    app/frontend/pluginReviewAnnotations.tsx
    app/frontend/pluginUiSlots.tsx
    app/frontend/pluginAgentProviderConnectPanels.tsx
    app/frontend/pluginArtifactRenderers.tsx
    app/frontend/pluginChatMessageRenderers.tsx
    app/frontend/pluginRuntimeSessionViews.tsx
    app/frontend/pluginToolCards.tsx
  ].freeze

  ALLOWED_PLUGIN_GLOB_FILES = %w[
    app/frontend/builtInPluginContributions.ts
    app/frontend/builtInPluginAgentProviderConnectPanels.ts
    app/frontend/builtInPluginArtifactRenderers.ts
    app/frontend/builtInPluginChatMessageRenderers.ts
    app/frontend/builtInPluginRuntimeSessionViews.ts
    app/frontend/builtInPluginToolCards.ts
    app/frontend/i18n/index.ts
    app/frontend/test/setup.ts
  ].freeze

  it "keeps build-time globs out of migrated contribution consumers" do
    offenders = MIGRATED_CONSUMERS.select do |path|
      source = Rails.root.join(path).read
      source.include?("import.meta.glob") && source.include?("plugins/*/app/frontend")
    end

    expect(offenders).to be_empty,
      "migrated consumers must read the shared registry instead of declaring import.meta.glob: #{offenders.join(', ')}"
  end

  it "keeps plugin globs in the built-in feed and locale loading only" do
    glob_files = Dir[Rails.root.join("app/frontend/**/*.{ts,tsx}")].filter_map do |file|
      source = File.read(file)
      next unless source.include?("import.meta.glob") && source.include?("plugins/*/app/frontend")

      Pathname(file).relative_path_from(Rails.root).to_s
    end

    expect(glob_files - ALLOWED_PLUGIN_GLOB_FILES).to be_empty,
      "plugin frontend globs must be registered through the shared built-in feed: #{(glob_files - ALLOWED_PLUGIN_GLOB_FILES).join(', ')}"
  end
end
