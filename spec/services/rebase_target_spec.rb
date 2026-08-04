require "rails_helper"

RSpec.describe RebaseTarget do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }

  describe ".branch_for" do
    it "returns the job's effective_base_branch when no workflow artifact is set" do
      job = Factories.job_record(user: user, repository: repository, state: "queued")

      expect(described_class.branch_for(job: job)).to eq("main")
    end

    it "prefers the workflow artifact over the job's effective_base_branch" do
      job = Factories.job_record(user: user, repository: repository, state: "queued")
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "rebase",
        artifacts: { RebaseTarget::BASE_BRANCH_ARTIFACT => "release/v2" }
      )

      expect(described_class.branch_for(job: job, workflow: workflow)).to eq("release/v2")
    end

    it "falls back to effective_base_branch when the workflow artifact is blank" do
      job = Factories.job_record(user: user, repository: repository, state: "queued")
      workflow = Workflow.create!(job: job, trigger_kind: "rebase", artifacts: {})

      expect(described_class.branch_for(job: job, workflow: workflow)).to eq("main")
    end

    it "works when workflow is nil" do
      job = Factories.job_record(user: user, repository: repository, state: "queued")

      expect(described_class.branch_for(job: job, workflow: nil)).to eq("main")
    end

    it "returns the open parent's branch when no artifact is set" do
      parent = Factories.job_record(user: user, repository: repository, state: "queued", branch_name: "syrus/parent-feat")
      child = Factories.job_record(user: user, repository: repository, state: "queued")
      child.update_columns(parent_job_id: parent.id)

      expect(described_class.branch_for(job: child)).to eq("syrus/parent-feat")
    end

    it "prefers the workflow artifact over the open parent branch" do
      parent = Factories.job_record(user: user, repository: repository, state: "queued", branch_name: "syrus/parent-feat")
      child = Factories.job_record(user: user, repository: repository, state: "queued")
      child.update_columns(parent_job_id: parent.id)
      workflow = Workflow.create!(
        job: child,
        trigger_kind: "rebase",
        artifacts: { RebaseTarget::BASE_BRANCH_ARTIFACT => "release/v3" }
      )

      expect(described_class.branch_for(job: child, workflow: workflow)).to eq("release/v3")
    end

    it "falls back to effective_base_branch when the parent is closed" do
      parent = Factories.job_record(user: user, repository: repository, state: "closed", branch_name: "syrus/parent-feat")
      child = Factories.job_record(user: user, repository: repository, state: "queued")
      child.update_columns(parent_job_id: parent.id)

      expect(described_class.branch_for(job: child)).to eq("main")
    end

    it "falls back to effective_base_branch when the parent has no branch" do
      parent = Factories.job_record(user: user, repository: repository, state: "queued", branch_name: nil)
      child = Factories.job_record(user: user, repository: repository, state: "queued")
      child.update_columns(parent_job_id: parent.id)

      expect(described_class.branch_for(job: child)).to eq("main")
    end
  end

  describe ".artifacts" do
    it "returns nil when there is no base branch and no PR to derive from" do
      expect(described_class.artifacts).to be_nil
    end

    it "sets BASE_BRANCH_ARTIFACT from explicit base_branch" do
      result = described_class.artifacts(base_branch: "release/v1")

      expect(result).to include(RebaseTarget::BASE_BRANCH_ARTIFACT => "release/v1")
    end

    it "sets BRANCH_ARTIFACT from the source branch name" do
      result = described_class.artifacts(branch_name: "syrus/issue-42")

      expect(result).to include(RebaseTarget::BRANCH_ARTIFACT => "syrus/issue-42")
    end

    it "sets BASE_BRANCH_ARTIFACT from the PR's base ref when base_branch is blank" do
      pr = double("pr", base: double(ref: "feature/shared", sha: "abc123"))

      result = described_class.artifacts(pr: pr)

      expect(result).to include(
        RebaseTarget::BASE_BRANCH_ARTIFACT => "feature/shared",
        RebaseTarget::BASE_SHA_ARTIFACT => "abc123"
      )
    end

    it "prefers explicit base_branch over the PR's base ref" do
      pr = double("pr", base: double(ref: "main", sha: "abc"))

      result = described_class.artifacts(base_branch: "hotfix/critical", pr: pr)

      expect(result[RebaseTarget::BASE_BRANCH_ARTIFACT]).to eq("hotfix/critical")
    end

    it "merges with an existing artifacts hash without losing existing keys" do
      pr = double("pr", base: double(ref: "main", sha: "deadbeef"))

      result = described_class.artifacts(artifacts: { "prior_key" => "prior_value" }, pr: pr)

      expect(result).to include("prior_key" => "prior_value")
      expect(result).to include(RebaseTarget::BASE_SHA_ARTIFACT => "deadbeef")
    end

    it "does not set BASE_SHA_ARTIFACT when the PR base SHA is blank" do
      pr = double("pr", base: double(ref: "main", sha: ""))

      result = described_class.artifacts(pr: pr)

      expect(result.keys).not_to include(RebaseTarget::BASE_SHA_ARTIFACT)
    end
  end
end
