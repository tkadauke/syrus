require "rails_helper"

RSpec.describe Workflows::Skill do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Skill: investigate",
      skill_name: "investigate",
      skill_args: { "question" => "What does the widget do?" }
    )
  end

  describe ".trigger_kind" do
    it "is skill" do
      expect(described_class.trigger_kind).to eq("skill")
    end
  end

  describe "chain" do
    it "is prepare → run_skill → summarize → pr_open" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[prepare run_skill summarize pr_open])
    end

    it "skips prepare when the job has skip_prepare set" do
      job.update!(skip_prepare: true)
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[run_skill summarize pr_open])
    end

    it "seeds skill_name/skill_args onto the workflow's artifacts" do
      workflow = described_class.instantiate(job: job, artifacts: job.skill_workflow_artifacts)

      expect(workflow.artifact("skill_name")).to eq("investigate")
      expect(workflow.artifact("skill_args")).to eq({ "question" => "What does the widget do?" })
    end
  end

  describe "no-diff closure" do
    it "closes the Job with closure_reason=no_changes instead of :failed when run_skill produces no diff" do
      job.update!(state: "running")
      workflow = Workflow.create!(job: job, trigger_kind: "skill", state: "running", started_at: 1.minute.ago)
      step = Step.create!(workflow: workflow, kind: "run_skill", position: 0, state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
      run = Run.create!(job: job, step: step, trigger_kind: "skill", state: "failed")
      run.create_run_diagnostic!(error_class: "Steps::Base::NoChangesProduced", error_message: "agent produced no changes")

      expect { workflow.fail!; workflow.save! }
        .to change { job.reload.state }.from("running").to("closed")
      expect(job.reload.closure_reason).to eq("no_changes")
    end
  end
end
