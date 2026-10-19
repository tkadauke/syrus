require "rails_helper"

RSpec.describe VisualReviewEvidenceGuard do
  let(:job) { Factories.job(issue_title: "Review chat", issue_body: "Review the /chats/1 route.") }

  def blocked_reason(text:, verdict: "approved", critique: "Looks good.")
    described_class.blocked_evidence_reason(
      job: job,
      artifacts: [ { "text" => text, "page" => { "path" => "/chats/1" } } ],
      verdict: verdict,
      critique: critique
    )
  end

  it "recognizes provider-specific credentials walls" do
    expect(blocked_reason(text: "Codex credentials are required.")).to include("credentials")
    expect(blocked_reason(text: "Gemini credentials needed to continue.")).to include("credentials")
  end

  it "does not classify ordinary provider content as blocked evidence" do
    expect(blocked_reason(text: "Codex reviewed the responsive chat layout.")).to be_nil
  end

  it "recognizes a skipped review caused by an environment blocker without screenshots" do
    reason = described_class.blocked_evidence_reason(
      job: job,
      artifacts: [],
      verdict: "skipped",
      critique: "Could not reach the intended route because preview authentication was unavailable."
    )

    expect(reason).to include("preview environment was blocked")
  end

  it "does not classify a non-visual skipped review as an environment blocker" do
    reason = described_class.blocked_evidence_reason(
      job: job,
      artifacts: [],
      verdict: "skipped",
      critique: "This backend-only refactor has no visual surface."
    )

    expect(reason).to be_nil
  end
end
