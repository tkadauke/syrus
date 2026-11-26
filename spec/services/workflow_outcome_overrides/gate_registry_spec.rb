require "rails_helper"

RSpec.describe WorkflowOutcomeOverrides::GateRegistry do
  it "registers gate contracts and denies unknown kinds" do
    registry = described_class.new
    gate = WorkflowOutcomeOverrides::GateKind.new("custom") { |failure| failure[:code] == "provider_error" }
    registry.register(gate)

    expect(registry.fetch("custom")).to eq(gate)
    expect { registry.fetch("missing") }.to raise_error(described_class::UnknownGateKind)
  end

  it "requires an explicit technical failure and rejects structural failures before the gate contract" do
    gate = WorkflowOutcomeOverrides::GateKind.new("custom") { true }

    expect(gate.overridable_failure?(outcome: "failed", technically_overridable: true, structural: false)).to be(true)
    expect(gate.overridable_failure?(outcome: "passed", technically_overridable: true, structural: false)).to be(false)
    expect(gate.overridable_failure?(outcome: "failed", technically_overridable: true, structural: true)).to be(false)
    expect(gate.overridable_failure?(outcome: "failed", technically_overridable: false, structural: false)).to be(false)
  end
end
