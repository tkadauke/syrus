require "rails_helper"

RSpec.describe Tailscale::StatusPayload do
  let(:dns_name) { "my-box.tail12345.ts.net." }
  let(:status_body) do
    {
      "BackendState" => "Running",
      "Self" => { "DNSName" => dns_name, "Online" => true }
    }.to_json
  end
  let(:http_response) { "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n#{status_body}" }
  let(:mock_socket) { instance_double(UNIXSocket, write: nil, flush: nil, read: http_response) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(File).to receive(:exist?).and_call_original
  end

  describe "#call" do
    context "when the daemon is not running" do
      before do
        allow(Tailscale::DaemonManager.instance).to receive(:alive?).and_return(false)
        allow(ENV).to receive(:[]).with("TS_AUTHKEY").and_return("tskey-auth-abc123")
        allow(File).to receive(:exist?).with("/dev/net/tun").and_return(true)
      end

      it "reports the daemon as not running and not connected" do
        payload = described_class.call

        expect(payload).to eq(
          daemon_running: false,
          connected: false,
          hostname: nil,
          tailscale_url: nil,
          auth_key_present: true,
          net_admin_capable: true
        )
      end
    end

    context "when the daemon is running and reachable" do
      before do
        allow(Tailscale::DaemonManager.instance).to receive(:alive?).and_return(true)
        allow(UNIXSocket).to receive(:open).and_yield(mock_socket)
        allow(ENV).to receive(:[]).with("TS_AUTHKEY").and_return("tskey-auth-abc123")
        allow(File).to receive(:exist?).with("/dev/net/tun").and_return(true)
      end

      it "reports connected status, hostname, and tailscale URL" do
        payload = described_class.call

        expect(payload).to eq(
          daemon_running: true,
          connected: true,
          hostname: "my-box.tail12345.ts.net",
          tailscale_url: "https://my-box.tail12345.ts.net",
          auth_key_present: true,
          net_admin_capable: true
        )
      end
    end

    context "when the daemon is running but the backend is still starting" do
      let(:status_body) do
        { "BackendState" => "Starting", "Self" => { "DNSName" => dns_name, "Online" => false } }.to_json
      end

      before do
        allow(Tailscale::DaemonManager.instance).to receive(:alive?).and_return(true)
        allow(UNIXSocket).to receive(:open).and_yield(mock_socket)
        allow(ENV).to receive(:[]).with("TS_AUTHKEY").and_return("tskey-auth-abc123")
        allow(File).to receive(:exist?).with("/dev/net/tun").and_return(true)
      end

      it "is not connected" do
        payload = described_class.call
        expect(payload[:connected]).to be(false)
      end
    end

    context "when the daemon is running but the local API is unreachable" do
      before do
        allow(Tailscale::DaemonManager.instance).to receive(:alive?).and_return(true)
        allow(UNIXSocket).to receive(:open).and_raise(Errno::ENOENT, "No such file")
        allow(ENV).to receive(:[]).with("TS_AUTHKEY").and_return(nil)
        allow(File).to receive(:exist?).with("/dev/net/tun").and_return(false)
      end

      it "does not raise and reports not connected" do
        payload = nil
        expect { payload = described_class.call }.not_to raise_error
        expect(payload).to eq(
          daemon_running: true,
          connected: false,
          hostname: nil,
          tailscale_url: nil,
          auth_key_present: false,
          net_admin_capable: false
        )
      end
    end
  end
end
