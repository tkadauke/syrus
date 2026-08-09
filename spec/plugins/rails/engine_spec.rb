require "rails_helper"

RSpec.describe SyrusRails::Engine do
  describe "PluginRegistry registration" do
    subject(:registration) do
      Syrus::PluginRegistry.all_plugins.find { |r| r.name == "syrus-rails" }
    end

    before do
      # The after_initialize block runs once at boot; plugin_registry.rb resets
      # the in-memory registry in test mode. Re-register here so examples see
      # the manifest. Interface modules were included during after_initialize
      # and are permanent on the classes.
      unless Syrus::PluginRegistry.registered_names.include?("syrus-rails")
        Syrus::PluginRegistry.register(
          name:        "syrus-rails",
          version:     SyrusRails::VERSION,
          description: "Ruby on Rails intelligence",
          homepage:    "https://github.com/tkadauke/syrus",
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

    after do
      Syrus::PluginRegistry.reset!
    end

    it "registers itself with Syrus::PluginRegistry" do
      expect(registration).not_to be_nil
    end

    it "registers with the correct metadata" do
      expect(registration.version).to eq(SyrusRails::VERSION)
      expect(registration.description).to eq("Ruby on Rails intelligence")
    end

    it "provides all 6 extension point keys" do
      expect(registration.provides.keys).to contain_exactly(
        :mcp_tool_set,
        :artifact_renderer,
        :test_result_parser,
        :coverage_analyzer,
        :prompt_injector,
        :preview_provider
      )
    end

    it "registers RspecParser as the :test_result_parser" do
      expect(registration.provides[:test_result_parser]).to eq(SyrusRails::RspecParser)
    end

    it "registers SimpleCovAnalyzer as the :coverage_analyzer" do
      expect(registration.provides[:coverage_analyzer]).to eq(SyrusRails::SimpleCovAnalyzer)
    end

    it "registers both artifact renderers as an array under :artifact_renderer" do
      renderers = Array(registration.provides[:artifact_renderer])
      expect(renderers).to include(SyrusRails::SchemaErdRenderer, SyrusRails::MigrationDiffRenderer)
    end
  end
end
