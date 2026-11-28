require "rails_helper"

RSpec.describe SyrusDev::InvariantAlertProvider do
  it "contributes the invariant banner while violations are open" do
    InvariantViolation.create!(invariant_key: "retry_storms", fingerprint: "retry_storms:Job:1", severity: "critical",
                               subject_type: "Job", subject_id: 1, message_params: {}, details: {},
                               first_detected_at: Time.current, last_detected_at: Time.current)

    expect(described_class.system_alerts.map(&:id)).to eq([ "invariant_violations" ])
  end

  it "contributes nothing when no violation is open" do
    expect(described_class.system_alerts).to eq([])
  end
end
