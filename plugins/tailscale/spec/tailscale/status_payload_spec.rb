require "rails_helper"

RSpec.describe Tailscale::StatusPayload do
  def stub_remote_status(status)
    allow(Tailscale::RemoteStatus).to receive(:call).and_return(status)
  end

  def stub_auth_key_present(present)
    settings = instance_double(Syrus::PluginSettings, present?: present)
    allow(Syrus::PluginSettings).to receive(:for).with("tailscale").and_return(settings)
  end

  describe "#call" do
    context "when the container is not reachable at all" do
      before do
        stub_remote_status(nil)
        stub_auth_key_present(false)
      end

      it "reports the daemon as not running and not connected" do
        expect(described_class.call).to eq(
          daemon_running: false,
          connected: false,
          hostname: nil,
          tailscale_url: nil,
          auth_key_present: false
        )
      end
    end

    context "when the container reports the daemon connected" do
      before do
        stub_remote_status("daemon_running" => true, "connected" => true, "hostname" => "my-box.tail12345.ts.net", "tailscale_ips" => [ "100.64.0.1" ])
        stub_auth_key_present(true)
      end

      it "reports connected status, hostname, and tailscale URL" do
        expect(described_class.call).to eq(
          daemon_running: true,
          connected: true,
          hostname: "my-box.tail12345.ts.net",
          tailscale_url: "https://my-box.tail12345.ts.net",
          auth_key_present: true
        )
      end
    end

    context "when the container is up but the backend is still starting" do
      before do
        stub_remote_status("daemon_running" => true, "connected" => false, "hostname" => "my-box.tail12345.ts.net")
        stub_auth_key_present(true)
      end

      it "is not connected" do
        expect(described_class.call[:connected]).to be(false)
      end

      it "still reports the daemon as running" do
        expect(described_class.call[:daemon_running]).to be(true)
      end
    end
  end
end
