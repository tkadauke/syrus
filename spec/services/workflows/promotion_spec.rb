require "rails_helper"

RSpec.describe Workflows::Promotion do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Promote develop into main"
    )
  end
  let(:artifacts) { { "promotion_source_branch" => "develop", "promotion_target_branch" => "main" } }

  describe ".instantiate" do
    it "requires promotion_source_branch and promotion_target_branch artifacts" do
      expect {
        described_class.instantiate(job: job, artifacts: {})
      }.to raise_error(ArgumentError, /promotion_source_branch and promotion_target_branch/)
    end

    it "sets trigger_kind to promotion" do
      workflow = described_class.instantiate(job: job, artifacts: artifacts)

      expect(workflow.trigger_kind).to eq("promotion")
    end

    it "seeds the workspace artifacts so WorkflowWorkspace checks out an integration branch off the target" do
      workflow = described_class.instantiate(job: job, artifacts: artifacts)

      expect(workflow.artifact("rebase_base_branch")).to eq("main")
      expect(workflow.artifact("rebase_branch")).to eq("syrus/promote-develop-main-#{job.id}")
      expect(workflow.artifact("promotion_source_branch")).to eq("develop")
      expect(workflow.artifact("promotion_target_branch")).to eq("main")
    end

    it "declares the chain shape" do
      workflow = described_class.instantiate(job: job, artifacts: artifacts)

      kinds = workflow.steps.order(:position).pluck(:kind)
      expect(kinds).to eq(%w[
        promotion_assemble prepare promotion_repair
        grader_fanout grader_collect
        promotion_publish
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
