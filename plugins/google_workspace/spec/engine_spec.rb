require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe "Google Workspace plugin" do
  let(:plugin) { syrus_plugin(__dir__ + "/..") }

  it "is a valid default-disabled experimental plugin" do
    expect(plugin).to be_plugin_loaded
    expect(plugin).to have_valid_plugin_manifest
    expect(plugin).to have_clean_plugin_host_surface
  end
end
