require "rails_helper"

RSpec.describe Workflows::AgentInsight do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) do
    # agent_insight jobs require the feature flag
    Feature.find_or_create_by!(slug: "agent_insights") do |f|
      f.category = "Labs"
      f.name     = "Agent Insights"
    end.update!(enabled: true)

    Job.create!(
      user:       user,
      repository: repository,
      kind:       "agent_insight",
      priority:   "low"
    )
  end

  describe "chain" do
    it "materializes prepare → agent_insight_run → auto_close" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[prepare agent_insight_run auto_close])
      expect(workflow.trigger_kind).to eq("agent_insight")
    end

    it "honors repository-level prepare disablement" do
      repository.update!(prepare_enabled: false)

      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[agent_insight_run auto_close])
      expect(workflow.artifact("prepare_skipped_reason")).to eq("repository_configuration")
    end

    it "uses the runs queue" do
      expect(described_class.queue_name).to eq(:runs)
    end
  end

  describe ".after_success" do
    let(:workflow) { described_class.instantiate(job: job) }

    it "closes the anchor Job with reason agent_insight" do
      described_class.after_success(workflow)

      expect(job.reload.state).to eq("closed")
      expect(job.reload.closure_reason).to eq("agent_insight")
    end

    it "is idempotent when the job is already closed" do
      workflow
      job.close_with_reason!("agent_insight")

      expect { described_class.after_success(workflow) }.not_to raise_error
      expect(job.reload.state).to eq("closed")
    end
  end

  describe ".after_fail" do
    let(:workflow) { described_class.instantiate(job: job) }

    it "closes the anchor Job with reason agent_insight" do
      described_class.after_fail(workflow)

      expect(job.reload.state).to eq("closed")
      expect(job.reload.closure_reason).to eq("agent_insight")
    end
  end

  describe "infrastructure_workflow?" do
    it "is treated as an infrastructure workflow" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.infrastructure_workflow?).to be true
    end

    it "does not propagate start to the job" do
      workflow = described_class.instantiate(job: job)
      workflow.start!
      workflow.save!

      # infrastructure_workflow? causes propagate_start_to_job! to skip
      expect(job.reload.state).not_to eq("running")
    end
  end

  describe "agent_insight job kind validation" do
    context "when the agent_insights feature is disabled" do
      before do
        Feature.find_or_create_by!(slug: "agent_insights") do |f|
          f.category = "Labs"
          f.name     = "Agent Insights"
        end.update!(enabled: false)
      end

      it "rejects job creation" do
        job = Job.new(user: user, repository: repository, kind: "agent_insight")

        expect(job).not_to be_valid
        expect(job.errors[:kind]).to include("agent_insights feature is disabled")
      end
    end

    context "when issue_number is set" do
      before do
        Feature.find_or_create_by!(slug: "agent_insights") do |f|
          f.category = "Labs"
          f.name     = "Agent Insights"
        end.update!(enabled: true)
      end

      it "rejects the job" do
        job = Job.new(user: user, repository: repository, kind: "agent_insight", issue_number: 1)

        expect(job).not_to be_valid
        expect(job.errors[:issue_number]).to include("must be blank for agent_insight Jobs")
      end
    end
  end
end
