require "rails_helper"

RSpec.describe Prompts::SummarizeAmendFallback do
  let(:issue) { Struct.new(:title, :body).new("Fix flaky timeout", "The rspec grader times out on slow machines.") }
  let(:diff)  { "diff --git a/feature.rb b/feature.rb\n-def greet = 'hello'\n+def greet = 'hello world'\n" }

  it "asks for follow-up commit metadata without provider resume" do
    out = described_class.new(
      issue: issue,
      trigger_kind: "ci_failure",
      upstream_step_kind: "analyze_and_fix",
      diff: diff
    ).to_s

    expect(out).to match(/original agent\s+session is not available to resume/)
    expect(out).to include("submit_summary")
    expect(out).to include("follow-up commit")
    expect(out).to include("not the whole PR")
    expect(out).to include("Do not edit files, run commands, or make commits")
  end

  it "embeds bounded durable context for the failed resume replacement" do
    out = described_class.new(
      issue: issue,
      trigger_kind: "ci_failure",
      upstream_step_kind: "analyze_and_fix",
      diff: diff
    ).to_s

    expect(out).to include("Trigger kind: ci_failure")
    expect(out).to include("Upstream step: analyze_and_fix")
    expect(out).to include("Title: Fix flaky timeout")
    expect(out).to include("The rspec grader times out")
    expect(out).to include("+def greet = 'hello world'")
  end

  it "truncates oversized bodies and diffs by safe UTF-8 byte boundaries" do
    big_issue = Struct.new(:title, :body).new("Fix flaky timeout", "x" * 20_000)
    big_diff = "diff --git a/feature.rb b/feature.rb\n+#{'x' * 100_000}\n"

    out = described_class.new(
      issue: big_issue,
      trigger_kind: "ci_failure",
      upstream_step_kind: "analyze_and_fix",
      diff: big_diff
    ).to_s

    expect(out).to include("[truncated")
    expect(out).to include("feature.rb")
    expect(out).to be_valid_encoding
  end
end
