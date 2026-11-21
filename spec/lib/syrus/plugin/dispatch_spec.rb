require "rails_helper"

RSpec.describe Syrus::Plugin::Dispatch do
  let(:context) { Syrus::Plugin::Context::RepoContext.new(repo_path: "/repo", repository: nil) }
  let(:health) { Syrus::PluginRuntimeHealth.new }

  before do
    Syrus::Plugin::Family.reset!
    Syrus::Plugin::Family.define(:dispatch_spec) do
      shape :facet
      capability :collect_items, composition: :collect, absent: [], tier: :stable, context: "RepoContext"
      capability :notify, composition: :broadcast, absent: nil, tier: :stable, context: "RepoContext"
      capability :claim, composition: :first_claim, absent: :unclaimed, tier: :stable, context: "RepoContext"
      capability :resolve, composition: :keyed, absent: nil, tier: :stable, context: "RepoContext"
    end
    Syrus::PluginInvocation.runtime_health = health
  end

  after do
    Syrus::Plugin::Family.reset!
    Syrus::PluginInvocation.runtime_health = Syrus::PluginRuntimeHealth.new
  end

  it "composes collect, broadcast, first-claim, and keyed capabilities" do
    calls = []
    collect_one = provider(:collect_one, Class.new { def self.collect_items(_context) = [ :one ] })
    collect_two = provider(:collect_two, Class.new { def self.collect_items(_context) = [ :two ] })
    notify_one = provider(:notify_one, Class.new { define_singleton_method(:notify) { |_context| calls << :one } })
    notify_two = provider(:notify_two, Class.new { define_singleton_method(:notify) { |_context| calls << :two } })
    decline = provider(:decline, Class.new { def self.claim(_context) = nil })
    claim = provider(:claim, Class.new { def self.claim(_context) = :claimed })
    keyed = provider(:ruby, Class.new { def self.resolve(_context) = :ruby })

    providers_for(collect_items: [ collect_one, collect_two ], notify: [ notify_one, notify_two ],
      claim: [ decline, claim ], resolve: [ keyed ])

    expect(described_class.call(:dispatch_spec, :collect_items, context)).to eq(%i[one two])
    expect(described_class.call(:dispatch_spec, :notify, context)).to be_nil
    expect(calls).to eq(%i[one two])
    expect(described_class.call(:dispatch_spec, :claim, context)).to eq(:claimed)
    expect(described_class.call(:dispatch_spec, :resolve, context, key: :ruby)).to eq(:ruby)
  end

  it "uses declared absent behavior and returns a typed missing-key error" do
    providers_for(collect_items: [], notify: [], claim: [], resolve: [])

    expect(described_class.call(:dispatch_spec, :collect_items, context)).to eq([])
    expect(described_class.call(:dispatch_spec, :claim, context)).to eq(:unclaimed)
    expect { described_class.call(:dispatch_spec, :resolve, context, key: :missing) }
      .to raise_error(described_class::MissingKey, /missing/)
  end

  it "uses declared absent behavior when every first-claim provider declines" do
    decline = provider(:decline_all, Class.new { def self.claim(_context) = nil })
    providers_for(claim: [ decline ])

    expect(described_class.call(:dispatch_spec, :claim, context)).to eq(:unclaimed)
  end

  it "contains provider crashes as neutral contributions and emits telemetry" do
    broken = Class.new { def self.collect_items(_context) = raise("broken") }
    healthy = Class.new { def self.collect_items(_context) = [ :healthy ] }
    providers_for(collect_items: [ provider(:broken, broken), provider(:healthy, healthy) ])
    expect(PerformanceLogging).to receive(:plugin_call)
      .with(extension_point: :dispatch_spec, provider: broken, operation: :collect_items).and_call_original
    expect(PerformanceLogging).to receive(:plugin_call)
      .with(extension_point: :dispatch_spec, provider: healthy, operation: :collect_items).and_call_original

    expect(described_class.call(:dispatch_spec, :collect_items, context)).to eq([ :healthy ])
    expect(health.failures.first).to have_attributes(plugin: "broken", operation: "collect_items")
  end

  it "continues first-claim dispatch after a provider crashes" do
    broken = Class.new { def self.claim(_context) = raise("broken") }
    healthy = Class.new { def self.claim(_context) = :healthy }
    providers_for(claim: [ provider(:broken_claim, broken), provider(:healthy_claim, healthy) ])

    expect(described_class.call(:dispatch_spec, :claim, context)).to eq(:healthy)
  end

  it "times out slow providers and opens their circuit" do
    calls = 0
    slow = Class.new do
      define_singleton_method(:collect_items) do |_context|
        calls += 1
        sleep 0.02
        [ :late ]
      end
    end
    providers_for(collect_items: [ provider(:slow, slow) ])

    6.times { expect(described_class.call(:dispatch_spec, :collect_items, context, timeout: 0.001)).to eq([]) }

    expect(calls).to eq(5)
    expect(health.circuits(plugin: "slow").sole.state).to eq(:open)
    expect(health.failures(plugin: "slow").sole.exception_class).to eq("Timeout::Error")
  end

  it "passes deliberate validation errors through without recording a crash" do
    invalid = Class.new do
      def self.claim(_context)
        raise Syrus::Plugin::Dispatch::ValidationError.new("invalid config", code: :invalid_config, details: { line: 2 })
      end
    end
    providers_for(claim: [ provider(:invalid, invalid) ])

    expect { described_class.call(:dispatch_spec, :claim, context) }
      .to raise_error(described_class::ValidationError) do |error|
        expect(error).to have_attributes(code: :invalid_config, details: { line: 2 })
      end
    expect(health.failures).to be_empty
  end

  def provider(key, implementation)
    stub_const("DispatchSpec#{key.to_s.camelize}", implementation)
    allow(Syrus::PluginRegistry).to receive(:plugin_name_for).with(implementation).and_return(key.to_s)
    Syrus::Plugin::CapabilityProvider.new(
      plugin_name: key.to_s, family: :dispatch_spec, capability: nil,
      provider_name: implementation.name, key:, priority: 0
    )
  end

  def providers_for(mapping)
    allow(Syrus::PluginRegistry).to receive(:capability_providers) do |_family, capability|
      mapping.fetch(capability, [])
    end
  end
end
