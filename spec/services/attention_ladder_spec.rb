require "rails_helper"

RSpec.describe AttentionLadder do
  # The ladder differs per work definition because the cost of being wrong
  # differs -- that is the whole reason it is not one global setting.
  it "spends a turn on judgment only where a stalled failure is expensive" do
    expect(described_class).to be_adjudicates("auto_merge")
    expect(described_class).to be_adjudicates("merge_train")

    expect(described_class).not_to be_adjudicates("initial")
    expect(described_class).not_to be_adjudicates("rebase")
  end

  # The next merge-state poll retries anyway; waking someone is worse than the
  # failure.
  it "never escalates a rebase" do
    expect(described_class).not_to be_escalates("rebase")
    expect(described_class).not_to be_escalates("stack_rebase")
  end

  it "escalates broken main, where everything is blocked" do
    expect(described_class).to be_escalates("main_branch_repair")
  end

  it "does not escalate a failed initial attempt, which is normal and cheap" do
    expect(described_class).not_to be_escalates("initial")
  end

  it "falls back to a ladder that escalates for an unknown trigger kind" do
    expect(described_class.for("something_new")).to eq(described_class::DEFAULT)
    expect(described_class).to be_escalates("something_new")
  end

  it "only names known rungs" do
    described_class::LADDERS.each do |kind, rungs|
      expect(rungs - described_class::RUNGS).to eq([]), "#{kind} names an unknown rung"
    end
  end
end
