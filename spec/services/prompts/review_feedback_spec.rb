require "rails_helper"

RSpec.describe Prompts::ReviewFeedback do
  it "returns nil when there are no iterations" do
    out = described_class.new(intro: "Reviewer flagged issues:", iterations: []).to_s

    expect(out).to be_nil
  end

  it "renders the intro followed by each finding" do
    iterations = [
      { "iteration" => 1, "critique" => "The rescue clause swallows a real error." },
      { "iteration" => 2, "critique" => "Missing a regression test for the timeout path." }
    ]

    out = described_class.new(intro: "Reviewer flagged issues:", iterations: iterations).to_s

    expect(out).to start_with("Reviewer flagged issues:")
    expect(out).to include("Iteration 1:\nThe rescue clause swallows a real error.")
    expect(out).to include("Iteration 2:\nMissing a regression test for the timeout path.")
  end

  it "tolerates symbol-keyed entries and missing critique text" do
    out = described_class.new(intro: "Reviewer flagged issues:", iterations: [ { iteration: 3 } ]).to_s

    expect(out).to include("Iteration 3:\n(No critique provided.)")
  end
end
