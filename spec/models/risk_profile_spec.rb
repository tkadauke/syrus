require "rails_helper"

RSpec.describe RiskProfile do
  it "offers the three postures the plan defines" do
    expect(described_class.keys).to eq(%w[prototype standard production])
  end

  # The point of a bundle: "how much do we tolerate a broken main" is one
  # question, and six booleans cannot answer it consistently.
  it "answers every governed setting for every profile" do
    described_class::BUILT_IN.each do |posture|
      described_class::GOVERNED.each do |setting|
        expect(posture.public_send(setting)).not_to be_nil, "#{posture.key} does not answer #{setting}"
      end
    end
  end

  it "escalates nothing and grades nothing for a prototype" do
    posture = described_class.fetch("prototype")

    expect(posture.main_branch_health_enabled).to be(false)
    expect(posture.escalates_landing_failures).to be(false)
  end

  # "Every override human and audited" is the production posture's whole point.
  it "forbids agentic dismissal in production only" do
    expect(described_class.fetch("production").allows_agentic_dismissal).to be(false)
    expect(described_class.fetch("standard").allows_agentic_dismissal).to be(true)
    expect(described_class.fetch("prototype").allows_agentic_dismissal).to be(true)
  end

  # Worth pinning: Syrus ships strict, so a fresh repository is production and
  # relaxing it is a deliberate act rather than a silent default change.
  it "names the shipped posture as production" do
    expect(described_class::SHIPPED_DEFAULT).to eq("production")

    shipped = described_class.fetch(described_class::SHIPPED_DEFAULT)
    expect(shipped.main_branch_repair_blocks_work).to be(true)
    expect(shipped.main_branch_breakage_policy).to eq(AppSetting.main_branch_breakage_policy)
  end

  describe ".resolve" do
    it "returns the profile's answer when nothing overrides it" do
      expect(described_class.resolve(:main_branch_repair_blocks_work, profile: "production")).to be(true)
    end

    it "lets an explicit override win, including a false one" do
      resolved = described_class.resolve(
        :main_branch_repair_blocks_work, profile: "production",
        overrides: { main_branch_repair_blocks_work: false }
      )

      expect(resolved).to be(false)
    end

    it "refuses a setting no profile governs" do
      expect { described_class.resolve(:polling_enabled, profile: "standard") }
        .to raise_error(ArgumentError, /not governed by a risk profile/)
    end

    it "refuses an unknown profile" do
      expect { described_class.fetch("yolo") }.to raise_error(ArgumentError, /unknown risk profile/)
    end
  end
end
