require "rails_helper"

RSpec.describe WorkGates do
  let(:snapshot) { Syrus::PluginRegistry.snapshot }

  after { Syrus::PluginRegistry.restore(snapshot) }

  def provider(&block)
    Class.new do
      define_singleton_method(:work_gate, &block)
    end
  end

  it "passes when no provider vetoes" do
    Syrus::PluginRegistry.restore(snapshot.with(direct_providers: {}))

    expect(described_class.evaluate).to be_pass
  end

  it "composes one or many typed vetoes" do
    first = Syrus::Plugin::WorkPolicy::Veto.new(reason: :maintenance, message: "Maintenance", landing: true)
    second = Syrus::Plugin::WorkPolicy::Veto.new(reason: :quota, message: "Quota exhausted")
    Syrus::PluginRegistry.register(:work_gate, provider { |_context| [ first ] })
    Syrus::PluginRegistry.register(:work_gate, provider { |_context| [ second ] })

    result = described_class.evaluate

    expect(result.vetoes).to include(first, second)
    expect(result).to be_veto
  end

  it "fails open and reports a provider error to plugin health" do
    runtime_health = instance_double(Syrus::PluginRuntimeHealth, allow?: true, record_success: nil, record_failure: nil)
    allow(Syrus::PluginInvocation).to receive(:runtime_health).and_return(runtime_health)
    broken = provider { |_context| raise "gate unavailable" }
    Syrus::PluginRegistry.register(:work_gate, broken)

    expect(described_class.evaluate).to be_pass
    expect(runtime_health).to have_received(:record_failure).with(
      hash_including(extension_point: :work_policy, operation: :work_gate, exception: an_instance_of(RuntimeError))
    )
  end
end
