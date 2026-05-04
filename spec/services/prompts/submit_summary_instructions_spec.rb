require "rails_helper"

RSpec.describe Prompts::SubmitSummaryInstructions do
  let(:text) { described_class::TEXT }

  it "instructs the agent to call the submit_summary MCP tool" do
    expect(text).to include("submit_summary")
    expect(text).to match(/CALL THE `submit_summary` MCP TOOL/)
  end

  it "documents all three required fields" do
    expect(text).to include("pr_title")
    expect(text).to include("pr_body")
    expect(text).to include("summary")
  end

  it "specifies imperative mood for pr_title" do
    expect(text).to match(/imperative mood/)
  end

  it "warns that pr_title becomes the git commit message on follow-up runs" do
    expect(text).to match(/follow-up runs/)
    expect(text).to match(/commit message/)
  end

  it "instructs the agent not to include title/body in final text" do
    expect(text).to match(/DO NOT include the title or body in your final assistant text/)
  end
end
