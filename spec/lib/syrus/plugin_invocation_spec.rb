# frozen_string_literal: true

require "rails_helper"

RSpec.describe Syrus::PluginInvocation do
  Provider = Class.new { include Syrus::Plugin::Callbacks }
  let(:clock) { Struct.new(:now).new(Time.utc(2026, 1, 1)) }
  let(:health) { Syrus::PluginRuntimeHealth.new(clock: -> { clock.now }) }

  before do
    described_class.runtime_health = health
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "invocation_spec", version: "1.0", provides: { callbacks: Provider })
  end

  after do
    described_class.runtime_health = Syrus::PluginRuntimeHealth.new
  end

  def invoke(**options, &block)
    described_class.call(
      extension_point: :callbacks, provider: Provider, operation: :call,
      failure_threshold: 2, failure_window: 10, cooldown: 20, on_decline: [],
      **options, &block
    )
  end

  it "returns successful values and preserves plugin-call telemetry" do
    expect(PerformanceLogging).to receive(:plugin_call)
      .with(extension_point: :callbacks, provider: Provider, operation: :call)
      .and_yield

    expect(invoke { [ "parsed" ] }).to eq([ "parsed" ])
  end

  it "represents expected declines without recording a failure" do
    result = invoke { described_class.decline([]) }

    expect(result).to eq(described_class::Declined.new(value: []))
    expect(health.failures).to be_empty
  end

  it "records failures and returns a typed failed decline" do
    result = invoke { raise ArgumentError, "bad provider" }

    expect(result).to have_attributes(value: [], exception_class: "ArgumentError", message: "bad provider", reason: :failed)
    expect(health.failures.first).to have_attributes(
      plugin: "invocation_spec", extension_point: "callbacks", operation: "call",
      exception_class: "ArgumentError", message: "bad provider", count: 1, last_at: clock.now
    )
  end

  it "opens, short-circuits, permits one half-open trial, and closes after success" do
    2.times { invoke { raise "broken" } }
    expect(health.circuits.first.state).to eq(:open)

    expect { |probe| invoke(&probe) }.not_to yield_control
    clock.now += 21
    expect(invoke { :recovered }).to eq(:recovered)
    expect(health.circuits).to be_empty
  end

  it "reopens when the half-open trial fails" do
    2.times { invoke { raise "broken" } }
    clock.now += 21

    invoke { raise "still broken" }

    expect(health.circuits.first).to have_attributes(state: :open, opened_at: clock.now)
  end

  it "closes when the half-open trial declines normally" do
    2.times { invoke { raise "broken" } }
    clock.now += 21

    expect(invoke { described_class.decline([]) }).to be_a(described_class::Declined)
    expect(health.circuits).to be_empty
  end

  it "times out only when a budget is supplied" do
    result = invoke(timeout: 0.001) { sleep 0.05 }

    expect(result).to have_attributes(reason: :timeout, exception_class: "Timeout::Error", value: [])
  end

  it "does not rescue exceptions outside StandardError" do
    expect { invoke { raise Interrupt } }.to raise_error(Interrupt)
  end

  it "records unimplemented provider operations as failures" do
    result = invoke { raise NotImplementedError, "optional operation" }

    expect(result).to be_a(described_class::Failed)
    expect(health.failures.last).to have_attributes(
      operation: "call", exception_class: "NotImplementedError", message: "optional operation"
    )
  end

  it "bounds distinct retained failures per plugin while preserving other plugins" do
    bounded_health = Syrus::PluginRuntimeHealth.new(clock: -> { clock.now }, max_failures_per_plugin: 2)
    3.times do |index|
      bounded_health.record_failure(
        plugin: "bounded", extension_point: :route, operation: :dispatch,
        exception: RuntimeError.new("failure #{index}"), threshold: 5, window: 60, cooldown: 30
      )
      clock.now += 1
    end
    bounded_health.record_failure(
      plugin: "sibling", extension_point: :route, operation: :dispatch,
      exception: RuntimeError.new("sibling failure"), threshold: 5, window: 60, cooldown: 30
    )

    expect(bounded_health.failures(plugin: "bounded").map(&:message)).to contain_exactly("failure 1", "failure 2")
    expect(bounded_health.failures(plugin: "sibling").map(&:message)).to eq([ "sibling failure" ])
  end

  # The hot path must stay in-process. Asserted structurally rather than as a
  # wall-clock budget: "below one millisecond per call" failed on loaded
  # graders whatever the code did, and tore down a landing bundle with it.
  it "keeps successful hot-path invocations in memory, with no database work or health state" do
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }
    results = Array.new(1_000) { |index| invoke { index } }
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(results).to eq((0...1_000).to_a)
    expect(queries).to be_empty
    expect(described_class.runtime_health.failures).to be_empty
  end
end
