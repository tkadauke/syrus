require "rails_helper"

RSpec.describe PluginRuntime::PurgeContributor do
  let(:managed) { PluginRuntime::Configuration.new("SYRUS_PLUGIN_RUNTIME_URL" => "http://plugin-runtime:8080", "SYRUS_PLUGIN_RUNTIME_TOKEN" => "t" * 32) }

  it "reports the plugin's volumes with their sizes" do
    stub_request(:get, "http://plugin-runtime:8080/v1/volumes").to_return(status: 200, body: { volumes: [
      { name: "syrus_plugin_git-mirror_data", plugin: "git_mirror", size_bytes: 1_288_490_189 },
      { name: "syrus_plugin_other_data", plugin: "other" }
    ] }.to_json)

    expect(described_class.purge_report("git_mirror", configuration: managed)).to eq([ "volume syrus_plugin_git-mirror_data (1.2 GB)" ])
  end

  it "purges them through the runtime manager" do
    purge = stub_request(:delete, "http://plugin-runtime:8080/v1/plugins/git_mirror")
      .to_return(status: 200, body: { removed_volumes: [ "syrus_plugin_git-mirror_data" ] }.to_json)

    expect(described_class.purge!("git_mirror", configuration: managed)).to eq([ "volume syrus_plugin_git-mirror_data" ])
    expect(purge).to have_been_requested
  end

  # On Kubernetes the operator owns the services and their storage.
  it "holds nothing when services are managed outside Syrus" do
    external = PluginRuntime::Configuration.new({})

    expect(described_class.purge_report("git_mirror", configuration: external)).to eq([])
    expect(described_class.purge!("git_mirror", configuration: external)).to eq([])
  end
end
