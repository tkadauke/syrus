require "rails_helper"

RSpec.describe WorkUnits::Gates::ManualPause do
  let(:intent) { WorkIntent.create!(kind: "initial", state: "requested", scope_type: "job", scope_id: 123) }
  let(:unit) { WorkUnit.create!(work_intent: intent, kind: "initial", state: "queued", scope_type: "job", scope_id: 123) }

  it "passes when no pause is requested" do
    expect(described_class.call(unit)).to be_pass
  end

  it "blocks when pause is requested" do
    unit.request_pause!

    result = described_class.call(unit)

    expect(result).to be_blocked
    expect(result.reason).to eq("manual_pause")
    expect(result.details).to include("pause_requested" => true)
  end
end
