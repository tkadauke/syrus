require "rails_helper"

RSpec.describe Workflows::HotfixSync do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Sync main into develop"
    )
  end
  let(:artifacts) { { "hotfix_sync_source_branch" => "main", "hotfix_sync_target_branch" => "develop" } }

  describe ".instantiate" do
    it "requires hotfix_sync_source_branch and hotfix_sync_target_branch artifacts" do
      expect {
        described_class.instantiate(job: job, artifacts: {})
      }.to raise_error(ArgumentError, /hotfix_sync_source_branch and hotfix_sync_target_branch/)
    end

    it "sets trigger_kind to hotfix_sync" do
      workflow = described_class.instantiate(job: job, artifacts: artifacts)

      expect(workflow.trigger_kind).to eq("hotfix_sync")
    end

    it "seeds the workspace artifacts so WorkflowWorkspace checks out an integration branch off the target" do
      workflow = described_class.instantiate(job: job, artifacts: artifacts)

      expect(workflow.artifact("rebase_base_branch")).to eq("develop")
      expect(workflow.artifact("rebase_branch")).to eq("syrus/hotfix-sync-main-develop-#{job.id}")
      expect(workflow.artifact("hotfix_sync_source_branch")).to eq("main")
      expect(workflow.artifact("hotfix_sync_target_branch")).to eq("develop")
    end

    it "declares the chain shape" do
      workflow = described_class.instantiate(job: job, artifacts: artifacts)

      kinds = workflow.steps.order(:position).pluck(:kind)
      expect(kinds).to eq(%w[
        hotfix_sync_assemble prepare hotfix_sync_repair
        grader_fanout grader_collect
        hotfix_sync_publish
      ])
    end

    it "uses the merges queue" do
      expect(described_class.queue_name).to eq(:merges)
    end

    it "honors repository-level prepare disablement" do
      repository.update!(prepare_enabled: false)

      workflow = described_class.instantiate(job: job, artifacts: artifacts)

      kinds = workflow.steps.order(:position).pluck(:kind)
      expect(kinds).not_to include("prepare")
    end
  end
end
