require "rails_helper"

RSpec.describe Prompts::SummarizeFallback do
  let(:issue) { Struct.new(:title, :body).new("Add greeting", "We need a greeting helper.") }
  let(:diff)  { "diff --git a/feature.rb b/feature.rb\n+def greet = 'hi'\n" }

  it "asks the agent to call submit_summary without editing files" do
    out = described_class.new(issue: issue, diff: diff).to_s

    expect(out).to include("bounded metadata-only context")
    expect(out).to include("submit_summary")
    expect(out).to include("exact prefixed name")
    expect(out).to include("Do not edit files, run commands, or make commits")
    expect(out).to match(/Do not continue\s+implementation/)
  end

  it "embeds bounded job context and a changed-file manifest" do
    out = described_class.new(issue: issue, diff: diff).to_s

    expect(out).to include("Title: Add greeting")
    expect(out).to include("We need a greeting helper.")
    expect(out).to include("feature.rb")
    expect(out).not_to include("def greet = 'hi'")
  end

  it "truncates oversized bodies by safe UTF-8 byte boundaries and never embeds diff bodies" do
    big_issue = Struct.new(:title, :body).new("Add greeting", "x" * 20_000)
    big_diff = "diff --git a/feature.rb b/feature.rb\n+#{'●' * 10_000}\n"

    out = described_class.new(issue: big_issue, diff: big_diff).to_s

    expect(out).to include("[truncated")
    expect(out).to include("feature.rb")
    expect(out).not_to include("+●")
    expect(out).to be_valid_encoding
  end
end
