require "rails_helper"

RSpec.describe Adjudication do
  it "settles the question when it upholds or dismisses" do
    expect(described_class.uphold(reason: "real")).to be_decided
    expect(described_class.dismiss(reason: "not_ours")).to be_decided
  end

  # The load-bearing verdict: a cheap rung that cannot tell must say so, or the
  # expensive rungs never get their turn.
  it "does not settle the question when inconclusive" do
    expect(described_class.inconclusive).not_to be_decided
  end

  it "carries the adjudicator and its evidence" do
    verdict = described_class.dismiss(reason: "inherited", adjudicator: "x", evidence: { names: [ "rspec" ] })

    expect(verdict.to_h).to eq(
      verdict: "dismiss", reason: "inherited", adjudicator: "x", evidence: { names: [ "rspec" ] }
    )
  end

  it "rejects a verdict outside the three" do
    expect { described_class.new(:maybe) }.to raise_error(ArgumentError, /unknown adjudication verdict/)
  end
end
