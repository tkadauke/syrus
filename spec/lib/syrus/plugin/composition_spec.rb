require "rails_helper"

RSpec.describe Syrus::Plugin::Composition do
  CompositionProvider = Struct.new(:implementation, :key) do
    def invoke = yield implementation
  end

  it "collects ordered contributions" do
    providers = [ CompositionProvider.new(:one), CompositionProvider.new(:two) ]
    expect(described_class.collect(providers) { |value| [ value, value ] }).to eq(%i[one one two two])
  end

  it "broadcasts to every provider and returns nil" do
    called = []
    result = described_class.broadcast([ CompositionProvider.new(:one), CompositionProvider.new(:two) ]) { |value| called << value }
    expect(called).to eq(%i[one two])
    expect(result).to be_nil
  end

  it "uses the first non-nil claim and treats nil and errors as declines" do
    providers = [
      CompositionProvider.new(:error),
      CompositionProvider.new(:decline),
      CompositionProvider.new(:claimed),
      CompositionProvider.new(:late)
    ]
    expect(Rails.logger).to receive(:warn).with(/Provider.*RuntimeError: declined/)
    result = described_class.first_claim(providers) do |value|
      raise "declined" if value == :error
      value == :decline ? nil : value
    end
    expect(result).to eq(:claimed)
  end

  it "selects a keyed provider and reports a missing key" do
    first = Class.new { def self.key = :first }
    second = Class.new { def self.key = :second }
    providers = [ CompositionProvider.new(first, :first), CompositionProvider.new(second, :second) ]
    expect(described_class.keyed(providers, :second) { |implementation| implementation.key }).to eq(:second)
    expect { described_class.keyed(providers, :missing) { nil } }.to raise_error(described_class::MissingKey, /missing/)
  end

  it "selects a keyed provider without invoking unselected providers" do
    selected = instance_double(Syrus::Plugin::CapabilityProvider, key: :selected)
    other = instance_double(Syrus::Plugin::CapabilityProvider, key: :other)
    allow(selected).to receive(:invoke).and_yield(:implementation)
    allow(other).to receive(:invoke)

    expect(described_class.keyed([ other, selected ], :selected) { |value| value }).to eq(:implementation)
    expect(other).not_to have_received(:invoke)
  end
end
