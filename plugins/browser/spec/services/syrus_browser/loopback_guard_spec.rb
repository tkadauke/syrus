require "rails_helper"

RSpec.describe SyrusBrowser::LoopbackGuard do
  describe ".allowed?" do
    it "allows http on 127.0.0.1" do
      expect(described_class.allowed?("http://127.0.0.1:3001/dashboard")).to be true
    end

    it "allows https on 127.0.0.1" do
      expect(described_class.allowed?("https://127.0.0.1:3001/dashboard")).to be true
    end

    it "allows any literal 127.x.x.x address, not just 127.0.0.1" do
      expect(described_class.allowed?("http://127.0.0.2:3001")).to be true
      expect(described_class.allowed?("http://127.255.255.255:3001")).to be true
    end

    it "allows localhost" do
      expect(described_class.allowed?("http://localhost:3001/dashboard")).to be true
    end

    it "allows localhost case-insensitively" do
      expect(described_class.allowed?("http://LOCALHOST:3001")).to be true
    end

    it "allows bracketed IPv6 loopback" do
      expect(described_class.allowed?("http://[::1]:3001")).to be true
    end

    it "rejects an external hostname" do
      expect(described_class.allowed?("http://evil.example.com")).to be false
    end

    it "rejects a private-network address that is not loopback" do
      expect(described_class.allowed?("http://192.168.1.1:3001")).to be false
      expect(described_class.allowed?("http://10.0.0.1:3001")).to be false
    end

    it "rejects a hostname that merely contains 127.0.0.1 as a substring" do
      expect(described_class.allowed?("http://127.0.0.1.evil.example.com")).to be false
    end

    it "rejects non-http(s) schemes even when the host is loopback" do
      expect(described_class.allowed?("file:///etc/passwd")).to be false
      expect(described_class.allowed?("javascript://127.0.0.1/%0aalert(1)")).to be false
    end

    it "rejects a URL with no host" do
      expect(described_class.allowed?("http:///dashboard")).to be false
    end

    it "rejects a malformed URL" do
      expect(described_class.allowed?("http://[::1")).to be false
    end

    it "rejects blank input" do
      expect(described_class.allowed?("")).to be false
      expect(described_class.allowed?(nil)).to be false
    end
  end
end
