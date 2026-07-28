require "rails_helper"

RSpec.describe RebaseWorkflowSelector do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, issue_number: 1, branch_name: "syrus/feat-1") }

  # JobStackResolver#force_main! clears parent_job_id for jobs without
  # dependency records, so we set it via update_columns after creation
  # to bypass that callback.
  def open_child_job(parent:, issue_number:, branch: "syrus/child-#{SecureRandom.hex(4)}")
    child = Factories.job(
      user: user,
      repository: repository,
      issue_number: issue_number,
      branch_name: branch,
      pr_number: issue_number * 10
    )
    child.update_columns(parent_job_id: parent.id)
    child
  end

  describe ".stack_rebase?" do
    it "returns false when the job has no stack children" do
      expect(described_class.stack_rebase?(job)).to be false
    end

    it "returns true when the job has open, rebaseable stack children" do
      child = open_child_job(parent: job, issue_number: 2)

      expect(described_class.stack_rebase?(job)).to be true
    end

    it "returns true for a leaf child whose parent is also open" do
      child = open_child_job(parent: job, issue_number: 2)

      expect(described_class.stack_rebase?(child)).to be true
    end

    it "returns true for a leaf job whose parent is open with a branch" do
      leaf = open_child_job(parent: job, issue_number: 4)

      expect(described_class.stack_rebase?(leaf)).to be true
    end

    it "returns false for a leaf job whose parent is closed" do
      leaf = open_child_job(parent: job, issue_number: 5)
      job.update_columns(state: "closed", closure_reason: "pr_merged")

      expect(described_class.stack_rebase?(leaf)).to be false
    end

    it "returns false for a leaf job whose parent has no branch" do
      job.update_columns(branch_name: nil)
      leaf = open_child_job(parent: job, issue_number: 6)

      expect(described_class.stack_rebase?(leaf)).to be false
    end
  end

  describe ".instantiate" do
    it "instantiates a Rebase workflow for a standalone (non-stack) job" do
      workflow = described_class.instantiate(job: job)

      expect(workflow).to be_a(Workflow)
      expect(workflow.trigger_kind).to eq("rebase")
    end

    it "instantiates a StackRebase workflow when the job has open stack descendants" do
      open_child_job(parent: job, issue_number: 3)

      workflow = described_class.instantiate(job: job)

      expect(workflow).to be_a(Workflow)
      expect(workflow.trigger_kind).to eq("stack_rebase")
    end

    it "instantiates a StackRebase workflow for a leaf job with an open parent branch" do
      leaf = open_child_job(parent: job, issue_number: 7)

      workflow = described_class.instantiate(job: leaf)

      expect(workflow).to be_a(Workflow)
      expect(workflow.trigger_kind).to eq("stack_rebase")
    end
  end

  describe ".active_for_stack?" do
    it "returns false when there are no active rebase workflows for the stack" do
      expect(described_class.active_for_stack?(job)).to be false
    end

    it "returns true when a running rebase workflow exists for a related job" do
      workflow = Workflow.create!(job: job, trigger_kind: "rebase")
      workflow.update_columns(state: "running")

      expect(described_class.active_for_stack?(job)).to be true
    end
  end

  describe ".active_in_repository" do
    it "returns no workflows when there are none active in the repository" do
      expect(described_class.active_in_repository(repository)).to be_empty
    end

    it "returns running rebase workflows in the given repository" do
      workflow = Workflow.create!(job: job, trigger_kind: "rebase")
      workflow.update_columns(state: "running")
      Step.create!(workflow: workflow, kind: "auto_rebase", position: 0)

      result = described_class.active_in_repository(repository)

      expect(result).to include(workflow)
    end

    it "excludes workflows from other repositories" do
      other_repo = Factories.repository(user: user)
      other_job = Factories.job_record(user: user, repository: other_repo, issue_number: 9)
      other_wf = Workflow.create!(job: other_job, trigger_kind: "rebase")
      other_wf.update_columns(state: "running")

      expect(described_class.active_in_repository(repository)).to be_empty
    end
  end
end
