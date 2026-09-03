require "rails_helper"

RSpec.describe Prompts::SummarizeAmendFallback do
  let(:issue) { Struct.new(:title, :body).new("Fix CI", "The lint grader is failing.") }
  let(:summary) { "Existing PR updates the workflow engine." }
  let(:diff) { "diff --git a/app.rb b/app.rb\n+puts 'fixed'\n" }

  it "asks the agent to call submit_summary without editing files" do
    out = described_class.new(issue: issue, summary: summary, diff: diff).to_s

    expect(out).to include("original agent session is not available to resume")
    expect(out).to include("follow-up commit")
    expect(out).to include("submit_summary")
    expect(out).to match(/exact prefixed\s+name/)
    expect(out).to include("Do not edit files, run commands, or make commits")
  end

  it "embeds bounded job, PR, and follow-up diff context" do
    out = described_class.new(issue: issue, summary: summary, diff: diff).to_s

    expect(out).to include("Title: Fix CI")
    expect(out).to include("The lint grader is failing.")
    expect(out).to include("Existing PR updates the workflow engine.")
    expect(out).to include("+puts 'fixed'")
  end

  it "truncates oversized inputs by safe UTF-8 byte boundaries" do
    big_issue = Struct.new(:title, :body).new("Fix CI", "x" * 20_000)
    big_summary = "y" * 10_000
    big_diff = "diff --git a/app.rb b/app.rb\n+#{'●' * 20_000}\n"

    out = described_class.new(issue: big_issue, summary: big_summary, diff: big_diff).to_s

    expect(out).to include("[truncated")
    expect(out).to include("diff --git a/app.rb b/app.rb")
    expect(out).to be_valid_encoding
  end
end
