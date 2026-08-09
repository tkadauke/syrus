require "rails_helper"

RSpec.describe Tailscale::HostAllowlist do
  let(:dns_name) { "mydevice.example.ts.net." }
  let(:tailscale_ips) { ["100.64.0.1", "fd7a::1"] }
  let(:status_body) do
    {
      "Self" => {
        "DNSName" => dns_name,
        "TailscaleIPs" => tailscale_ips
      }
    }.to_json
  end
  let(:http_response) { "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n#{status_body}" }
  let(:mock_socket) { instance_double(UNIXSocket, write: nil, flush: nil, read: http_response) }
  let(:hosts) { [] }

  before do
    described_class.instance_variable_set(:@added_entries, nil)
    allow(UNIXSocket).to receive(:open).and_yield(mock_socket)
    allow(Rails.application.config).to receive(:hosts).and_return(hosts)
  end

  describe ".sync" do
    it "adds the hostname with trailing dot stripped" do
      described_class.sync
      expect(hosts).to include("mydevice.example.ts.net")
      expect(hosts).not_to include("mydevice.example.ts.net.")
    end

    it "adds all TailscaleIPs" do
      described_class.sync
      expect(hosts).to include("100.64.0.1", "fd7a::1")
    end

    it "does not duplicate entries already present in config.hosts" do
      hosts << "100.64.0.1"
      described_class.sync
      expect(hosts.count("100.64.0.1")).to eq(1)
    end

    it "tracks exactly the entries it added" do
      described_class.sync
      expect(described_class.instance_variable_get(:@added_entries))
        .to contain_exactly("mydevice.example.ts.net", "100.64.0.1", "fd7a::1")
    end

    it "does not track entries that were already in config.hosts" do
      hosts << "100.64.0.1"
      described_class.sync
      expect(described_class.instance_variable_get(:@added_entries))
        .not_to include("100.64.0.1")
    end

    context "when the local API is unreachable" do
      before { allow(UNIXSocket).to receive(:open).and_raise(Errno::ENOENT, "No such file") }

      it "does not raise" do
        expect { described_class.sync }.not_to raise_error
      end

      it "logs a warning" do
        allow(Rails.logger).to receive(:warn)
        described_class.sync
        expect(Rails.logger).to have_received(:warn).with(/sync failed/)
      end
    end
  end

  describe ".clear" do
    before { described_class.sync }

    it "removes the hostname added by sync" do
      described_class.clear
      expect(hosts).not_to include("mydevice.example.ts.net")
    end

    it "removes the IPs added by sync" do
      described_class.clear
      expect(hosts).not_to include("100.64.0.1", "fd7a::1")
    end

    it "does not remove entries that were already in config.hosts before sync" do
      pre_existing = "pre-existing.example.com"
      hosts << pre_existing
      described_class.instance_variable_set(:@added_entries, nil)
      described_class.sync
      described_class.clear
      expect(hosts).to include(pre_existing)
    end

    it "resets the tracked entries" do
      described_class.clear
      expect(described_class.instance_variable_get(:@added_entries)).to eq([])
    end

    context "when nothing was synced" do
      before { described_class.instance_variable_set(:@added_entries, nil) }

      it "does not raise" do
        expect { described_class.clear }.not_to raise_error
      end
    end
  end
end
