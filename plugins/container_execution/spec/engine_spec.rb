require "rails_helper"

RSpec.describe "ContainerExecution plugin" do
  it "is disabled by default and provides an execution backend" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "container_execution" }

    expect(manifest).to be_present
    expect(manifest.default_enabled?).to be(false)
    expect(manifest.disableable?).to be(true)
    expect(manifest.provides[:execution_backend]).to eq(ContainerExecution::Backend)
  end
end
