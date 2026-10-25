require "rails_helper"

RSpec.describe ProviderRouting::PanelConsensus do
  def evaluate(verdicts, consensus: "majority", min_members: 1)
    described_class.call(member_verdicts: verdicts, consensus: consensus, min_members: min_members)
  end

  it "requires strictly more than half for majority and rejects an even tie" do
    result = evaluate(%w[approved approved needs_work needs_work])

    expect(result.verdict).to eq("needs_work")
    expect(result.breakdown).to include("approved" => 2, "needs_work" => 2, "required_approvals" => 3)
  end

  it "excludes skipped votes and recomputes majority quorum" do
    result = evaluate([ { verdict: "approved" }, { verdict: "needs_work" }, { verdict: "skipped" } ])

    expect(result.verdict).to eq("needs_work")
    expect(result.breakdown).to include("counted" => 2, "skipped" => 1, "required_approvals" => 2)
  end

  it "supports unanimous and at_least consensus" do
    expect(evaluate(%w[approved approved], consensus: "unanimous").verdict).to eq("approved")
    expect(evaluate(%w[approved needs_work approved], consensus: { at_least: 2 }).verdict).to eq("approved")
    expect(evaluate(%w[approved needs_work], consensus: { at_least: 2 }).verdict).to eq("needs_work")
  end

  it "returns skipped when counted membership falls below min_members" do
    result = evaluate(%w[approved skipped skipped], consensus: "unanimous", min_members: 2)

    expect(result.verdict).to eq("skipped")
    expect(result.breakdown).to include("counted" => 1, "min_members" => 2)
  end
end
