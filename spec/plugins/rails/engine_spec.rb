require "rails_helper"

RSpec.describe SyrusRails::Engine do
  describe "PluginRegistry registration" do
    subject(:registration) do
      Syrus::PluginRegistry.registrations.find { |r| r.name == "syrus-rails" }
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
