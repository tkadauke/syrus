require "rails_helper"

RSpec.describe Prompts::SubmitReportInstructions do
  let(:text) { described_class::TEXT }

  it "instructs the agent to call the submit_report MCP tool" do
    expect(text).to include("submit_report")
    expect(text).to match(/prefixed name/)
    expect(text).to include("do not call bare")
  end

  it "documents title, narrative, and findings" do
    expect(text).to include("`title`")
    expect(text).to include("`narrative`")
    expect(text).to include("`findings`")
  end

  it "requires useful scratch work to be inlined, summarized, or submitted as artifacts" do
    expect(text).to include("scratch files or local edits")
    expect(text).to match(/include the\s+relevant content, summary, or evidence/)
    expect(text).to include("reference artifacts")
    expect(text).to match(/Do not tell the operator to retrieve files\s+from the workflow workspace/)
    expect(text).to match(/not durable\s+repository deliverables/)
  end

  it "documents the references field and how to resolve visual artifact types" do
    expect(text).to include("`references`")
    expect(text).to include("submit_artifact")
    expect(text).to include("submit_visual_artifact")
    expect(text).to match(/type.*doesn't match anything is\s+rejected/)
  end
end
