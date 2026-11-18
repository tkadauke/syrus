# frozen_string_literal: true

require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe "external plugin validation" do
  let(:plugin) { syrus_plugin(ENV.fetch("SYRUS_PLUGIN_TEST_ROOT")) }

  it "satisfies the complete distributable plugin contract" do
    expect(plugin).to be_plugin_loaded
    expect(plugin).to be_plugin_healthy
    expect(plugin).to have_valid_plugin_manifest
    expect(plugin).to have_no_third_party_runtime_gems
    expect(plugin).to satisfy_requires_syrus
    expect(plugin).to have_clean_plugin_host_surface
    expect(plugin).to have_plugin_frontend
    expect(plugin).to have_matching_plugin_locales
  end
end
