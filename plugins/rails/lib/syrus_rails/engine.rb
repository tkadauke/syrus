require "rails"

module SyrusRails
  class Engine < ::Rails::Engine
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name: "syrus-rails",
        version: SyrusRails::VERSION,
        description: "Ruby on Rails intelligence",
        homepage: "https://github.com/tkadauke/syrus",
        provides: {
          mcp_tool_set:       SyrusRails::McpToolSet,
          artifact_renderer:  [SyrusRails::SchemaErdRenderer, SyrusRails::MigrationDiffRenderer],
          test_result_parser: SyrusRails::RspecParser,
          coverage_analyzer:  SyrusRails::SimpleCovAnalyzer,
          prompt_injector:    SyrusRails::PromptContext,
          preview_provider:   SyrusRails::PreviewProvider
        }
      )
    end
  end
end
