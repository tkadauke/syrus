require "rails_helper"

RSpec.describe "Tailscale plugin" do
  it "registers with PluginRegistry and appears in all_plugins" do
    plugin = Syrus::PluginRegistry.all_plugins.find { |p| p.name == "tailscale" }
    expect(plugin).not_to be_nil
    expect(plugin.display_name).to eq("Tailscale")
    expect(plugin.category).to eq("connectivity")
    expect(plugin.version).to eq(Tailscale::VERSION)
    expect(plugin.default_enabled).to eq(false)
    expect(plugin.disableable).to eq(true)
    expect(plugin.home_queue).to eq(:connectivity)
    expect(plugin.tick_interval).to eq(30.seconds)
    expect(plugin.config_schema).to include(hash_including(key: "auth_key", type: :secret_env))
  end
end
