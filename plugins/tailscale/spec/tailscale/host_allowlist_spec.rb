require "rails_helper"

RSpec.describe Tailscale::HostAllowlist do
  let(:dns_name) { "mydevice.example.ts.net" }
  let(:tailscale_ips) { [ "100.64.0.1", "fd7a::1" ] }
  let(:remote_status) { { "hostname" => dns_name, "tailscale_ips" => tailscale_ips } }
  let(:hosts) { [] }

  before do
    described_class.instance_variable_set(:@added_entries, nil)
    allow(Tailscale::RemoteStatus).to receive(:call).and_return(remote_status)
    allow(Rails.application.config).to receive(:hosts).and_return(hosts)
  end

  describe ".sync" do
    it "adds the hostname" do
      described_class.sync
      expect(hosts).to include("mydevice.example.ts.net")
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

    context "when the container is not reachable" do
      let(:remote_status) { nil }

      it "does not raise" do
        expect { described_class.sync }.not_to raise_error
      end

      it "adds nothing" do
        described_class.sync
        expect(hosts).to be_empty
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
