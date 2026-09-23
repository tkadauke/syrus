require "rails_helper"

RSpec.describe Tailscale::RemoteStatus do
  describe ".call" do
    it "returns nil when the service has no endpoint" do
      allow(PluginRuntime::Services).to receive(:endpoint_for).with("tailscale").and_return(nil)

      expect(described_class.call).to be_nil
    end

    it "fetches and parses /status from the container's endpoint" do
      allow(PluginRuntime::Services).to receive(:endpoint_for).with("tailscale").and_return("http://tailscale:8080")
      stub_request(:get, "http://tailscale:8080/status")
        .to_return(status: 200, body: { daemon_running: true, connected: true, hostname: "box.tail.ts.net" }.to_json)

      expect(described_class.call).to eq(
        "daemon_running" => true, "connected" => true, "hostname" => "box.tail.ts.net"
      )
    end

    it "returns nil and logs a warning when the container answers with an error" do
      allow(PluginRuntime::Services).to receive(:endpoint_for).with("tailscale").and_return("http://tailscale:8080")
      stub_request(:get, "http://tailscale:8080/status").to_return(status: 502)
      allow(Rails.logger).to receive(:warn)

      expect(described_class.call).to be_nil
    end

    it "returns nil and does not raise when the container is unreachable" do
      allow(PluginRuntime::Services).to receive(:endpoint_for).with("tailscale").and_return("http://tailscale:8080")
      stub_request(:get, "http://tailscale:8080/status").to_raise(Errno::ECONNREFUSED)

      expect { expect(described_class.call).to be_nil }.not_to raise_error
    end
  end
end
