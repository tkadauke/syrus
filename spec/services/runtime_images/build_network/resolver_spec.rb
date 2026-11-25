require "rails_helper"

RSpec.describe RuntimeImages::BuildNetwork::Resolver do
  def resolver(*answers) = described_class.new(lookup: ->(_host) { answers.flatten })

  it "returns the validated addresses" do
    expect(resolver("93.184.216.34", "93.184.216.34").resolve("example.com")).to eq([ "93.184.216.34" ])
  end

  it "fails the whole lookup when any answer is forbidden (mixed records, rebinding)" do
    expect { resolver("93.184.216.34", "127.0.0.1").resolve("example.com") }
      .to raise_error(described_class::Blocked) { |e| expect(e.reason).to eq("destination_address_forbidden") }
  end

  it "blocks private, metadata, and IPv4-mapped answers by default" do
    %w[10.0.0.1 169.254.169.254 ::ffff:192.168.0.1 fd00:ec2::254].each do |address|
      expect { resolver(address).resolve("example.com") }.to raise_error(described_class::Blocked), address
    end
  end

  it "lets private space through for an internal mirror but still never metadata or loopback" do
    expect(resolver("10.0.0.7").resolve("m.corp.example", allow_private: true)).to eq([ "10.0.0.7" ])
    expect { resolver("169.254.169.254").resolve("m.corp.example", allow_private: true) }.to raise_error(described_class::Blocked)
    expect { resolver("127.0.0.1").resolve("m.corp.example", allow_private: true) }.to raise_error(described_class::Blocked)
  end

  it "reports unresolvable names" do
    expect { resolver.resolve("nope.example.com") }.to raise_error(described_class::Blocked) { |e| expect(e.reason).to eq("dns_unresolved") }
    failing = described_class.new(lookup: ->(_) { raise SocketError, "boom" })
    expect { failing.resolve("nope.example.com") }.to raise_error(described_class::Blocked) { |e| expect(e.reason).to eq("dns_unresolved") }
  end
end
