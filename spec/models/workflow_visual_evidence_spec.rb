require "rails_helper"

RSpec.describe WorkflowVisualEvidence do
  it "limits the prunable scope to drafts" do
    run = Factories.job.initial_run
    draft = run.workflow.visual_evidences.create!(
      run:, step: run.step, sequence: 1, status: "draft", captured_at: 8.days.ago,
      content_digest: Digest::SHA256.hexdigest("draft")
    )
    run.workflow.visual_evidences.create!(
      run:, step: run.step, sequence: 2, status: "submitted", captured_at: 8.days.ago,
      content_digest: Digest::SHA256.hexdigest("submitted")
    )

    expect(described_class.prunable).to contain_exactly(draft)
  end
end
