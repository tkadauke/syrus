require "rails_helper"
require "syrus/plugin_documentation"

RSpec.describe Syrus::PluginDocumentation do
  subject(:documentation) { described_class.new }

  it "keeps the generated host API reference current" do
    expect(described_class::HOST_API_PATH.read).to eq(documentation.host_api),
      "Plugin host API documentation is stale. Run bin/generate-plugin-docs."
  end

  it "keeps the generated single-file plugin specification current" do
    expect(described_class::PLUGIN_SPEC_PATH.read).to eq(documentation.plugin_spec),
      "Plugin specification is stale. Run bin/generate-plugin-docs."
  end

  it "documents every accepted manifest declaration" do
    infrastructure = %i[
      build! discard_engine! effects install! lib_dir manifest_arguments
      metric_declarations namespace resolved_provides routes suggestion
    ]
    accepted = [ :name, :requires_syrus,
      *Syrus::PluginApi::Definition.public_instance_methods(false) - infrastructure ].uniq
    schema = Syrus::PluginApi::Definition::MANIFEST_SCHEMA

    expect(schema.keys).to contain_exactly(*accepted)
    accepted.each { |key| expect(documentation.plugin_spec).to include("`#{key}`") }
  end

  it "documents every registered extension point" do
    Syrus::PluginRegistry::EXTENSION_POINTS.each do |point|
      expect(documentation.plugin_spec).to include("- `#{point}` —")
    end
  end
end
