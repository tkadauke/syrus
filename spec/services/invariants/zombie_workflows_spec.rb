require "rails_helper"

RSpec.describe Invariants::ZombieWorkflows do
  let(:later) { Time.current + 3.hours }

  def job_with(workflow_state:, step_state:, run_state:, job_state: "running")
    Factories.job_with_run(state: job_state, workflow_attrs: { state: workflow_state }, step_attrs: { state: step_state },
                           run_attrs: { state: run_state })
  end

  describe "zombie workflows" do
    it "reports a running workflow with no active step or run" do
      job = job_with(workflow_state: "running", step_state: "failed", run_state: "failed")
      workflow = job.workflows.first

      violation = described_class.call(now: later).find { |v| v.discriminator == "zombie_workflow" }

      expect(violation.subject_id).to eq(workflow.id)
      expect(violation.details).to include("condition" => "zombie_workflow", "active_steps" => 0, "active_runs" => 0)
      expect(violation.message).to include(workflow.slug)
    end

    it "does not report a workflow with an active run" do
      job_with(workflow_state: "running", step_state: "running", run_state: "running")

      expect(described_class.call(now: later)).to be_empty
    end

    it "does not report a workflow whose unit is blocked on a named reason" do
      job = job_with(workflow_state: "queued", step_state: "succeeded", run_state: "succeeded", job_state: "queued")
      attach_work_unit(job.workflows.first, state: "blocked", blocked_reason: "admission_control")

      expect(described_class.call(now: later)).to be_empty
    end

    it "does not report recent activity" do
      job_with(workflow_state: "running", step_state: "failed", run_state: "failed")

      expect(described_class.call(now: Time.current + 30.minutes)).to be_empty
    end
  end

  describe "Job and workflow drift" do
    it "reports a running Job whose latest workflow ended" do
      job = job_with(workflow_state: "failed", step_state: "failed", run_state: "failed")
      job.workflows.first.update_columns(finished_at: Time.current)

      violation = described_class.call(now: later).sole

      expect(violation.discriminator).to eq("job_workflow_drift")
      expect(violation.subject_id).to eq(job.id)
      expect(violation.details["condition"]).to eq("job_running_workflow_failed")
    end

    it "gives a blocked workflow the longer blocked threshold" do
      job = job_with(workflow_state: "blocked", step_state: "blocked", run_state: "blocked")
      job.workflows.first.update_columns(finished_at: Time.current)

      expect(described_class.call(now: later)).to be_empty

      violation = described_class.call(now: Time.current + 4.days).sole
      expect(violation.details["condition"]).to eq("job_running_workflow_blocked")
    end

    it "does not report a running Job with an active workflow" do
      job_with(workflow_state: "running", step_state: "running", run_state: "running")

      expect(described_class.call(now: Time.current + 4.days)).to be_empty
    end
  end
end
