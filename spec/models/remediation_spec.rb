require "rails_helper"

RSpec.describe Remediation do
  it "carries an action, its arguments, and the tier that decided" do
    remediation = described_class[:repair_with, source: :template_override, kind: "landing_fix"]

    expect(remediation.action).to eq(:repair_with)
    expect(remediation.args).to eq(kind: "landing_fix")
    expect(remediation.source).to eq(:template_override)
    expect(remediation).to be_repair_with
  end

  it "rejects an action outside the closed set" do
    expect { described_class[:improvise, source: :problem_default] }
      .to raise_error(ArgumentError, /unknown remediation action/)
  end

  it "rejects a source outside the resolution rule" do
    expect { described_class[:fail, source: :vibes] }
      .to raise_error(ArgumentError, /unknown remediation source/)
  end

  # The two actions that end in a person are the ones the engine cannot carry
  # out alone; everything else it can.
  it "knows which actions need a human" do
    expect(described_class[:retry_step, source: :problem_default]).to be_automatic
    expect(described_class[:escalate, source: :problem_default]).not_to be_automatic
    expect(described_class[:fail, source: :problem_default]).not_to be_automatic
  end
end
