require "rails"

module SyrusRails
  class Engine < ::Rails::Engine
    config.after_initialize do
      # Wire up interface modules now that Zeitwerk is active and all
      # Syrus::Plugin::* constants are autoloadable from the main app's lib/.
      SyrusRails::McpToolSet.include(Syrus::Plugin::McpToolSet)
      SyrusRails::SchemaErdRenderer.include(Syrus::Plugin::ArtifactRenderer)
      SyrusRails::MigrationDiffRenderer.include(Syrus::Plugin::ArtifactRenderer)
      SyrusRails::PromptContext.include(Syrus::Plugin::PromptInjector)
      SyrusRails::PreviewProvider.include(Syrus::Plugin::PreviewProvider)

      Syrus::PluginRegistry.register(
        name:        "syrus-rails",
        version:     SyrusRails::VERSION,
        description: "Ruby on Rails intelligence",
        homepage:    "https://github.com/tkadauke/syrus",
        author:      "Thomas Kadauke",
        icon_url:    "/plugin-icons/syrus-rails.svg",
        category:    "language",
        depends_on:  [ "ruby" ],
        provides: {
          mcp_tool_set:      SyrusRails::McpToolSet,
          artifact_renderer: [SyrusRails::SchemaErdRenderer, SyrusRails::MigrationDiffRenderer],
          prompt_injector:   SyrusRails::PromptContext,
          preview_provider:  SyrusRails::PreviewProvider
        }
      )
    end
  end
end
