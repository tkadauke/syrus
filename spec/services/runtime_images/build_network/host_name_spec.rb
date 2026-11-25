require "rails_helper"

RSpec.describe RuntimeImages::BuildNetwork::HostName do
  %w[127.0.0.1 2130706433 0x7f.0.0.1 0177.0.0.1 127.1 [::1] ::1 10.0.0.1 169.254.169.254 1.2.3.4].each do |literal|
    it "treats #{literal} as a literal IP" do
      expect(described_class.literal?(literal)).to be(true)
      expect(described_class.normalize(literal)).to be_nil
    end
  end

  it "normalizes DNS names" do
    expect(described_class.normalize("Registry.NPMJS.org.")).to eq("registry.npmjs.org")
    expect(described_class.literal?("cafe.example.com")).to be(false)
  end

  it "rejects names that are not plain ASCII DNS hosts" do
    ["", "localhost", "a_b.example.com", "exämple.com", "-a.example.com", "a..example.com", "host name.com", "x" * 64 + ".com"].each do |host|
      expect(described_class.normalize(host)).to be_nil, host.inspect
    end
  end
end
