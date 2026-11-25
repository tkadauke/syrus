require "rails_helper"

RSpec.describe RuntimeImages::BuildNetwork::AddressGuard do
  {
    "93.184.216.34" => :public, "2606:4700:4700::1111" => :public,
    "127.0.0.1" => :loopback, "::1" => :loopback,
    "169.254.169.254" => :metadata, "100.100.100.200" => :metadata, "fd00:ec2::254" => :metadata,
    "169.254.1.1" => :link_local, "fe80::1" => :link_local,
    "0.0.0.0" => :unspecified, "224.0.0.1" => :multicast, "255.255.255.255" => :reserved,
    "10.1.2.3" => :private, "172.16.0.1" => :private, "192.168.1.1" => :private, "fd12::1" => :private,
    "100.64.0.1" => :shared_address_space, "198.18.0.1" => :reserved, "2002::1" => :reserved
  }.each do |address, label|
    it "classifies #{address} as #{label}" do
      expect(described_class.classify(address)).to eq(label)
    end
  end

  it "judges IPv4-mapped and NAT64 addresses by the IPv4 address they embed" do
    expect(described_class.classify("::ffff:127.0.0.1")).to eq(:loopback)
    expect(described_class.classify("::ffff:10.0.0.1")).to eq(:private)
    expect(described_class.classify("64:ff9b::a9fe:a9fe")).to eq(:metadata)
    expect(described_class.classify("64:ff9b::5db8:d822")).to eq(:public)
  end

  it "only lets private space through when explicitly allowed, and never loopback or metadata" do
    expect(described_class.blocked?("10.0.0.5")).to be(true)
    expect(described_class.blocked?("10.0.0.5", allow_private: true)).to be(false)
    expect(described_class.blocked?("100.64.0.1", allow_private: true)).to be(false)
    %w[127.0.0.1 169.254.169.254 100.100.100.200 fe80::1 0.0.0.0].each do |address|
      expect(described_class.blocked?(address, allow_private: true)).to be(true), address
    end
  end
end
