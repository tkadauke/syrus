require "rails_helper"

RSpec.describe LandingValidationPrefetchSource do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "approved") }
  let(:workflow) { Workflows::LandingValidation.instantiate(job: job) }

  it "releases the child-owned snapshot and bundle" do
    snapshot = WorkflowSourceSnapshots.record!(workflow: workflow, creator_step: workflow.steps.first,
      source_sha: "abc", tree_sha: "tree", source_ref: "prefetch-bundle:#{workflow.id}")
    snapshot.source_bundle.attach(io: StringIO.new("bundle"), filename: "source.bundle")

    expect { described_class.release!(workflow) }.to change(WorkflowSourceSnapshot, :count).by(-1)
    expect(ActiveStorage::Attachment.where(record_type: "WorkflowSourceSnapshot", record_id: snapshot.id)).not_to exist
  end

  %w[succeeded failed cancelled].each do |state|
    it "releases retained source material after child #{state}" do
      allow(WorkflowWorkspace).to receive(:cleanup_for).with(workflow).and_return(true)
      workflow.update_columns(state: state, cleaned_up_at: Time.current)
      snapshot = WorkflowSourceSnapshots.record!(workflow: workflow, creator_step: workflow.steps.first,
        source_sha: "abc", tree_sha: "tree", source_ref: "prefetch-bundle:#{workflow.id}")
      snapshot.source_bundle.attach(io: StringIO.new("bundle"), filename: "source.bundle")

      workflow.cleanup_workspace!

      expect(WorkflowSourceSnapshot.where(id: snapshot.id)).not_to exist
    end
  end
end
