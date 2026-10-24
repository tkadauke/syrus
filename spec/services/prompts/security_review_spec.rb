require "rails_helper"

RSpec.describe Prompts::SecurityReview do
  it "renders security concerns, context, prior findings, criteria, and the submission tool" do
    issue = Struct.new(:title, :body).new("Secure endpoint", "Add an endpoint")
    prompt = described_class.new(
      issue: issue, diff: "diff --git a/app.rb b/app.rb\n", base_ref: "main",
      prior_findings: [ { "iteration" => 1, "verdict" => "needs_work", "critique" => "Missing authorization" } ],
      criteria: [ "Check tenant boundaries" ], workflow_kind: "pr_comment", feedback_context: "review note"
    ).to_s

    expect(prompt).to include("authentication and authorization", "Missing authorization", "Check tenant boundaries", "review note", "submit_security_review")
  end
end
