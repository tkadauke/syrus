require "rails_helper"

RSpec.describe Prompts::RefreshJobMetadata do
  it "caps every potentially large workflow field with an explicit marker" do
    job = Struct.new(:title, :issue_body).new("Title", "i" * (described_class::MAX_BODY_BYTES + 1))
    pr = Struct.new(:title, :body).new("PR", "p" * (described_class::MAX_BODY_BYTES + 1))

    out = described_class.new(
      job: job,
      current_pr: pr,
      feedback: "f" * (described_class::MAX_FEEDBACK_BYTES + 1),
      prior_summaries: [ "s" * (described_class::MAX_SUMMARIES_BYTES + 1) ],
      diff: "d" * (described_class::MAX_DIFF_BYTES + 1)
    ).to_s

    expect(out).to include("[issue body truncated")
    expect(out).to include("[PR body truncated")
    expect(out).to include("[feedback truncated")
    expect(out).to include("[prior summaries truncated")
    expect(out).to include("[diff truncated")
    expect(out.bytesize).to be < 110_000
  end
end
