require "rails_helper"

RSpec.describe SsrfGuard do
  describe ".safe_host?" do
    before do
      allow(Addrinfo).to receive(:getaddrinfo).and_raise(SocketError)
    end

    def stub_resolution(host, *ips)
      allow(Addrinfo).to receive(:getaddrinfo)
        .with(host, nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
        .and_return(ips.map { |ip| instance_double(Addrinfo, ip_address: ip) })
    end

    it "allows ordinary public hostnames" do
      stub_resolution("uploads.example.com", "93.184.216.34")

      expect(described_class.safe_host?("uploads.example.com")).to be true
    end

    it "allows public IPv4 literals" do
      expect(described_class.safe_host?("93.184.216.34")).to be true
    end

    it "blocks loopback hostnames and IPs" do
      expect(described_class.safe_host?("localhost")).to be false
      expect(described_class.safe_host?("localhost.")).to be false
      expect(described_class.safe_host?("127.0.0.1")).to be false
      expect(described_class.safe_host?("127.5.5.5")).to be false
      expect(described_class.safe_host?("::1")).to be false
    end

    it "blocks libc-accepted loopback aliases that IPAddr does not parse" do
      stub_resolution("127.1", "127.0.0.1")
      stub_resolution("2130706433", "127.0.0.1")
      stub_resolution("0x7f000001", "127.0.0.1")
      stub_resolution("017700000001", "127.0.0.1")

      expect(described_class.safe_host?("127.1")).to be false
      expect(described_class.safe_host?("2130706433")).to be false
      expect(described_class.safe_host?("0x7f000001")).to be false
      expect(described_class.safe_host?("017700000001")).to be false
    end

    it "blocks link-local addresses, including the cloud metadata IP" do
      expect(described_class.safe_host?("169.254.169.254")).to be false
      expect(described_class.safe_host?("169.254.169.254.")).to be false
    end

    it "blocks known internal metadata hostnames" do
      expect(described_class.safe_host?("metadata.google.internal")).to be false
      expect(described_class.safe_host?("metadata.google.internal.")).to be false
    end

    it "blocks RFC1918 private ranges" do
      expect(described_class.safe_host?("10.0.0.5")).to be false
      expect(described_class.safe_host?("172.16.4.4")).to be false
      expect(described_class.safe_host?("192.168.1.1")).to be false
    end

    it "blocks IPv6 unique-local and link-local ranges" do
      expect(described_class.safe_host?("fc00::1")).to be false
      expect(described_class.safe_host?("fe80::1")).to be false
    end

    it "blocks hostnames that resolve to blocked ranges" do
      stub_resolution("assets.example.test", "93.184.216.34", "10.0.0.5")

      expect(described_class.safe_host?("assets.example.test")).to be false
    end

    it "blocks hosts that cannot be resolved" do
      expect(described_class.safe_host?("missing.example.test")).to be false
    end

    it "blocks blank hosts" do
      expect(described_class.safe_host?(nil)).to be false
      expect(described_class.safe_host?("")).to be false
    end
  end
end
