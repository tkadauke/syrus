require "rails_helper"

RSpec.describe JobStackResolver, :ci_only do
  let(:job) { Factories.job }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }

  # Regression for the stack-child git-state-corruption false positive:
  # RebaseTarget.branch_for prefers a pinned `rebase_base_branch` Workflow
  # artifact over recomputing `open_parent_branch(job)` live. Before this
  # fix, JobStackResolver only ever populated that artifact for the fan-in
  # ("prepared_stack_base") case -- an ordinary single-parent stack
  # resolution left `resolution.artifacts` empty, so every fresh
  # WorkflowWorkspace instance within the Workflow re-resolved the parent
  # branch from the parent Job's *current* live state. If the parent closed
  # partway through the Workflow, a later Run's recomputed base_ref could
  # diverge from what the original clone actually fetched.
  describe "#resolve!" do
    it "pins the resolved single stack parent's branch onto the result artifacts" do
      prerequisite = Factories.job(repository: job.repository, issue_number: 99)
      prerequisite.update!(branch_name: "syrus/issue-99-#{prerequisite.id}", pr_number: 99)
      prerequisite.runs.create!(trigger_kind: "initial", agent_provider: prerequisite.agent_provider, head_sha: "c" * 40)
      JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")

      result = described_class.new(job, workflow: workflow).resolve!

      expect(result).to be_ready
      expect(result.parent).to eq(prerequisite)
      expect(result.artifacts).to eq(RebaseTarget::BASE_BRANCH_ARTIFACT => prerequisite.branch_name)
    end

    it "pins the branch even when the Job already points at that parent (no-op update path)" do
      prerequisite = Factories.job(repository: job.repository, issue_number: 99)
      prerequisite.update!(branch_name: "syrus/issue-99-#{prerequisite.id}", pr_number: 99)
      prerequisite.runs.create!(trigger_kind: "initial", agent_provider: prerequisite.agent_provider, head_sha: "c" * 40)
      JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")
      job.update!(parent_job: prerequisite)

      result = described_class.new(job, workflow: workflow).resolve!

      expect(result.artifacts).to eq(RebaseTarget::BASE_BRANCH_ARTIFACT => prerequisite.branch_name)
    end

    it "does not pin anything when the Job has no stackable parent (falls back to the default branch)" do
      result = described_class.new(job, workflow: workflow).resolve!

      expect(result).to be_ready
      expect(result.parent).to be_nil
      expect(result.artifacts).to eq({})
    end
  end
end
