require "rails_helper"

RSpec.describe SsrfGuard do
  describe ".safe_host?" do
    it "allows ordinary public hostnames" do
      expect(described_class.safe_host?("uploads.example.com")).to be true
    end

    it "allows public IPv4 literals" do
      expect(described_class.safe_host?("93.184.216.34")).to be true
    end

    it "blocks loopback hostnames and IPs" do
      expect(described_class.safe_host?("localhost")).to be false
      expect(described_class.safe_host?("127.0.0.1")).to be false
      expect(described_class.safe_host?("127.5.5.5")).to be false
      expect(described_class.safe_host?("::1")).to be false
    end

    it "blocks link-local addresses, including the cloud metadata IP" do
      expect(described_class.safe_host?("169.254.169.254")).to be false
    end

    it "blocks known internal metadata hostnames" do
      expect(described_class.safe_host?("metadata.google.internal")).to be false
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

    it "blocks blank hosts" do
      expect(described_class.safe_host?(nil)).to be false
      expect(described_class.safe_host?("")).to be false
    end
  end
end
