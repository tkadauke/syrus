require "rails_helper"

RSpec.describe WorkUnits::Scheduler do
  let(:intent) { WorkIntent.create!(kind: "initial", state: "requested", scope_type: "job", scope_id: 123) }
  let(:unit) { WorkUnit.create!(work_intent: intent, kind: "initial", state: "queued", scope_type: "job", scope_id: 123) }

  it "blocks a unit when a gate returns a typed block result" do
    gate = Class.new do
      def self.call(_unit)
        WorkUnits::GateResult.block(reason: "resource_safety", retry_at: 1.minute.from_now, details: { "load" => "high" })
      end
    end

    result = described_class.evaluate!(unit, gates: [ gate ])

    expect(result).to be_blocked
    expect(unit.reload).to have_attributes(state: "blocked", blocked_reason: "resource_safety")
    expect(unit.blocked_details).to include("load" => "high")
  end

  it "unblocks a blocked unit when its owning gate passes" do
    unit.block!(reason: "manual_pause", details: { "pause_requested" => true })
    unit.clear_pause!

    result = described_class.evaluate!(unit)

    expect(result).to be_pass
    expect(unit.reload).to have_attributes(state: "queued", blocked_reason: nil)
  end

  it "does not unblock a unit blocked by a reason outside the evaluated gates" do
    unit.block!(reason: "dependency_failed", details: { "dependency_id" => 123 })

    result = described_class.evaluate!(unit)

    expect(result).to be_pass
    expect(unit.reload).to have_attributes(state: "blocked", blocked_reason: "dependency_failed")
  end

  it "uses manual pause as the first built-in gate" do
    unit.request_pause!

    result = described_class.evaluate!(unit)

    expect(result).to be_blocked
    expect(unit.reload).to have_attributes(state: "blocked", blocked_reason: "manual_pause")
  end

  it "uses the work unit definition's gates by default" do
    stub_definition = instance_double(WorkDefinitions::Initial, unit_gates: [])
    allow(unit).to receive(:definition).and_return(stub_definition)
    unit.request_pause!

    result = described_class.evaluate!(unit)

    expect(result).to be_pass
    expect(unit.reload).to have_attributes(state: "queued", blocked_reason: nil)
  end
end
