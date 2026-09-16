require "rails_helper"

# SampleGlobalMetricsJob iterates Syrus::Metrics.samplers rather than a
# hardcoded list -- the acceptance test for "adding a sampler needs no change
# to this file" is registering a spec-local class and asserting it gets
# sampled without this file (or SampleGlobalMetricsJob itself) knowing its
# name (see CLAUDE.md, "Core specs must not enumerate plugin-provided
# things" -- the same instinct applies to samplers in general).
RSpec.describe SampleGlobalMetricsJob do
  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  it "samples every registered sampler without naming any of them" do
    probe = Class.new do
      class << self
        attr_accessor :sampled
      end

      def self.sample! = self.sampled = true
      def self.refresh_gauges! = true
    end
    Syrus::Metrics.register_sampler(probe)

    described_class.perform_now

    expect(probe.sampled).to be(true)
  end

  it "does not let one sampler's failure stop the rest from being sampled" do
    failing = Class.new do
      def self.sample! = raise("boom")
      def self.refresh_gauges! = true
    end
    succeeding = Class.new do
      class << self
        attr_accessor :sampled
      end

      def self.sample! = self.sampled = true
      def self.refresh_gauges! = true
    end
    Syrus::Metrics.register_sampler(failing)
    Syrus::Metrics.register_sampler(succeeding)

    expect { described_class.new.perform }.not_to raise_error
    expect(succeeding.sampled).to be(true)
  end
end
