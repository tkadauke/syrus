host_root = ENV.fetch("SYRUS_HOST_ROOT")
require File.join(host_root, "spec/spec_helper")
require File.join(host_root, "config/environment")
require "rspec/rails"
require "syrus/plugin/test_kit"

RSpec.describe "relocatable plugin host contract" do
  let(:plugin) { syrus_plugin(ENV.fetch("RELOCATABLE_PLUGIN_ROOT")) }
  let(:session) { ActionDispatch::Integration::Session.new(Rails.application) }
  let(:user) { build_plugin_user }

  before do
    session.post("/session", params: { email_address: user.email_address, password: "supersecret" })
  end

  it "loads healthily from its declared external root" do
    expect(plugin).to be_plugin_loaded
    expect(plugin).to be_plugin_healthy
    expect(plugin).to have_valid_plugin_manifest
    expect(plugin).to satisfy_requires_syrus
    expect(plugin).to have_clean_plugin_host_surface
  end

  it "registers its provider and route" do
    expect(plugin).to register_plugin_provider(:callbacks).matching(RelocatablePlugin::Callbacks)
    expect(plugin).to have_plugin_route("/api/v1/app/relocatable_plugin/ping").using(session)
    expect(JSON.parse(session.response.body)).to include("location" => "external")
  end

  it "applies its migration" do
    expect(plugin).to have_applicable_plugin_migrations
    expect(ActiveRecord::Base.connection).to be_table_exists(:relocatable_plugin_probes)
  end

  it "ships a content-hashed frontend and matching locales" do
    expect(plugin).to have_plugin_frontend
    expect(plugin).to have_matching_plugin_locales
  end

  it "advertises and executes its CLI command" do
    expect(plugin).to have_plugin_cli_command("relocation", "ping").executable_with(user)
  end

  it "isolates incompatible and raising neighboring plugins" do
    expect(Syrus::PluginRegistry.health.status("future_plugin").state).to eq(:incompatible)
    expect(Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == "future_plugin" }.loaded).to be(false)
    expect(Syrus::PluginRegistry.health.status("exploding_plugin").state).to eq(:failed)
    expect(plugin).to be_plugin_loaded
  end
end
