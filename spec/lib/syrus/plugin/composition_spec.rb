require "rails_helper"

RSpec.describe Syrus::Plugin::Composition do
  Provider = Struct.new(:implementation) do
    def invoke = yield implementation
  end

  it "collects ordered contributions" do
    providers = [ Provider.new(:one), Provider.new(:two) ]
    expect(described_class.collect(providers) { |value| [ value, value ] }).to eq(%i[one one two two])
  end

  it "broadcasts to every provider and returns nil" do
    called = []
    result = described_class.broadcast([ Provider.new(:one), Provider.new(:two) ]) { |value| called << value }
    expect(called).to eq(%i[one two])
    expect(result).to be_nil
  end

  it "uses the first non-nil claim and treats nil and errors as declines" do
    providers = [ Provider.new(:error), Provider.new(:decline), Provider.new(:claimed), Provider.new(:late) ]
    result = described_class.first_claim(providers) do |value|
      raise "declined" if value == :error
      value == :decline ? nil : value
    end
    expect(result).to eq(:claimed)
  end

  it "selects a keyed provider and reports a missing key" do
    first = Class.new { def self.key = :first }
    second = Class.new { def self.key = :second }
    providers = [ Provider.new(first), Provider.new(second) ]
    expect(described_class.keyed(providers, :second) { |implementation| implementation.key }).to eq(:second)
    expect { described_class.keyed(providers, :missing) { nil } }.to raise_error(described_class::MissingKey, /missing/)
  end
end
