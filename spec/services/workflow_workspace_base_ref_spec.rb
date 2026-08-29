require "rails_helper"

RSpec.describe WorkflowWorkspace do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }

  describe ".base_ref_for" do
    it "uses origin/<default> for an unstacked job" do
      job = Factories.job_record(user: user, repository: repository)

      expect(described_class.base_ref_for(job)).to eq("origin/main")
    end

    it "uses the open parent branch for a stacked job" do
      parent = Factories.job_record(
        user: user,
        repository: repository,
        state: "open",
        branch_name: "syrus/direct-parent",
        pr_number: 41
      )
      child = Factories.job_record(user: user, repository: repository, parent_job: parent)

      expect(described_class.base_ref_for(child)).to eq("origin/syrus/direct-parent")
    end

    it "uses a workflow base artifact over the default branch" do
      job = Factories.job_record(user: user, repository: repository)
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        artifacts: { RebaseTarget::BASE_BRANCH_ARTIFACT => "syrus/prepared-base" }
      )

      expect(described_class.base_ref_for(job, workflow: workflow)).to eq("origin/syrus/prepared-base")
    end
  end
end
