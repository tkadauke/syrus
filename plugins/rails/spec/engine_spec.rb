require "rails_helper"

RSpec.describe SyrusRails::Engine do
  describe "PluginRegistry registration" do
    subject(:registration) do
      Syrus::PluginRegistry.all_plugins.find { |r| r.name == "syrus-rails" }
    end

    it "registers itself with Syrus::PluginRegistry" do
      expect(registration).not_to be_nil
    end

    it "registers with the correct metadata" do
      expect(registration.version).to eq(Syrus::Host::PluginApi.default_version)
      expect(registration.description).to eq("Ruby on Rails framework intelligence.")
      expect(registration.category).to eq("language")
    end

    it "registers its Ecosystem provider and keeps its unrelated extension points" do
      expect(registration.provides.keys).to contain_exactly(
        :mcp_tool_set,
        :artifact_renderer,
        :preview_provider
      )
      expect(registration.family_provides.map { |entry| [ entry.provider, entry.capabilities ] })
        .to eq([ [ "SyrusRails::Ecosystem", %i[prompt_context] ] ])
    end

    it "registers both artifact renderers as an array under :artifact_renderer" do
      renderers = Array(registration.provides[:artifact_renderer])
      expect(renderers).to include(SyrusRails::SchemaErdRenderer, SyrusRails::MigrationDiffRenderer)
    end

    it "declares a dependency on the ruby plugin" do
      expect(registration.depends_on).to eq([ "ruby" ])
    end
  end
end
