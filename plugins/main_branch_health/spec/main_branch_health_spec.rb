require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe "Main branch health plugin" do
  let(:plugin) { syrus_plugin(File.expand_path("..", __dir__)) }

  it "satisfies the host contract" do
    expect(plugin).to be_plugin_loaded
    expect(plugin).to be_plugin_healthy
    expect(plugin).to register_plugin_provider(:callbacks)
    expect(plugin).to have_valid_plugin_manifest
    expect(plugin).to satisfy_requires_syrus
    expect(plugin).to have_applicable_plugin_migrations
    expect(plugin).to have_plugin_frontend
    expect(plugin).to have_matching_plugin_locales
  end
end
