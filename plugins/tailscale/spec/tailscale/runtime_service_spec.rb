require "rails_helper"

RSpec.describe Tailscale::RuntimeService do
  def stub_settings(auth_key: "tskey-auth-abc123", hostname: nil, exit_node: false)
    allow(Syrus::PluginSettings).to receive(:get).with("tailscale", "auth_key").and_return(auth_key)
    allow(Syrus::PluginSettings).to receive(:get).with("tailscale", "hostname").and_return(hostname)
    allow(Syrus::PluginSettings).to receive(:get).with("tailscale", "exit_node").and_return(exit_node)
  end

  describe ".privileged_service_name" do
    it "is tailscale" do
      expect(described_class.privileged_service_name).to eq("tailscale")
    end
  end

  describe ".privileged_env" do
    it "sends only the auth key by default" do
      stub_settings

      expect(described_class.privileged_env).to eq("TS_AUTHKEY" => "tskey-auth-abc123")
    end

    it "includes the hostname override when configured" do
      stub_settings(hostname: "syrus-home")

      expect(described_class.privileged_env).to include("TS_HOSTNAME" => "syrus-home")
    end

    it "includes TS_EXIT_NODE only when the setting is true" do
      stub_settings(exit_node: true)
      expect(described_class.privileged_env).to include("TS_EXIT_NODE" => "true")

      stub_settings(exit_node: false)
      expect(described_class.privileged_env).not_to have_key("TS_EXIT_NODE")
    end

    # This is the whole of how "enabling without an auth key does nothing"
    # continues to work: ManagedDriver rescues this and reports an error
    # status instead of asking the runtime manager for a container.
    it "raises when no auth key is configured" do
      stub_settings(auth_key: nil)

      expect { described_class.privileged_env }.to raise_error(/TS_AUTHKEY is not configured/)
    end

    it "never includes anything but the three allowed keys" do
      stub_settings(hostname: "syrus-home", exit_node: true)

      expect(described_class.privileged_env.keys).to match_array(%w[TS_AUTHKEY TS_HOSTNAME TS_EXIT_NODE])
    end
  end
end
