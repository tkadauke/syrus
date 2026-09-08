require "rails_helper"

RSpec.describe RuntimeTerminal::Engine do
  it "is a Rails::Engine" do
    expect(described_class.superclass).to eq(Rails::Engine)
  end

  it "registers RuntimeTerminal::Provider as the :runtime_session_provider provider" do
    PluginRecord.find_or_create_by!(name: "terminal").update!(enabled: true, disableable: true)
    PluginRecord.find_or_create_by!(name: "runtime_terminal").update!(enabled: true, disableable: true)

    expect(Syrus::PluginRegistry.providers_for(:runtime_session_provider)).to include(RuntimeTerminal::Provider)
  end

  it "registers a manifest named 'runtime_terminal' with a terminal dependency" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == "runtime_terminal" }

    expect(manifest).not_to be_nil
    expect(manifest.depends_on).to eq([ "terminal" ])
  end

  it "includes the RuntimeSessionProvider plugin interface module" do
    expect(RuntimeTerminal::Provider.ancestors).to include(Syrus::Plugin::RuntimeSessionProvider)
  end
end
