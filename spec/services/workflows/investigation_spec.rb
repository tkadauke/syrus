require "rails_helper"

RSpec.describe Workflows::Investigation do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Investigation: what's slow about the dashboard?",
      issue_body: "Figure out why /dashboard feels slow.",
      investigation: true
    )
  end

  describe ".trigger_kind" do
    it "is investigation" do
      expect(described_class.trigger_kind).to eq("investigation")
    end
  end

  describe "chain" do
    it "is prepare → investigate → submit_report → auto_close" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[prepare investigate submit_report auto_close]
      )
    end

    it "skips prepare when the job has skip_prepare set" do
      job.update!(skip_prepare: true)
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[investigate submit_report auto_close]
      )
    end
  end

  describe "job lifecycle" do
    it "does not own the parent Job's lifecycle -- ordinary success/failure propagation applies" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.work_definition).not_to be_manages_own_job_lifecycle
      expect(Workflow::TriggerKind.owns_job_lifecycle?(workflow.trigger_kind)).to eq(false)
    end

    it "closes the Job successfully via the auto_close step, not an after_success hook" do
      job.update!(state: "running")
      workflow = described_class.instantiate(job: job)

      %w[investigate submit_report].each do |kind|
        step = workflow.steps.find_by!(kind: kind)
        Run.create!(job: job, step: step, trigger_kind: "investigation", state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
      end
      auto_close_step = workflow.steps.find_by!(kind: "auto_close")
      Steps::AutoClose.new(Run.create!(job: job, step: auto_close_step, trigger_kind: "investigation")).call

      expect(job.reload.state).to eq("closed")
      expect(job.closure_reason).to eq("investigation_reported")
    end

    it "leaves a failed investigate/submit_report step for the normal Retry path" do
      job.update!(state: "running")
      workflow = described_class.instantiate(job: job)
      investigate_step = workflow.steps.find_by!(kind: "investigate")
      run = Run.create!(job: job, step: investigate_step, trigger_kind: "investigation", state: "failed")
      run.create_run_diagnostic!(error_class: "Steps::Base::StepFailed", error_message: "agent exited 1")

      expect { StepDispatcher.fail_from(investigate_step) }
        .to change { job.reload.state }.from("running").to("failed")

      expect(workflow.reload).to be_failed
    end
  end
end
