require "rails_helper"

RSpec.describe App::RetryState do
  describe ".for" do
    it "does not report an old failed workflow while a newer workflow is active" do
      job = Factories.job
      failed_workflow = job.latest_workflow
      failed_workflow.update!(
        state: "failed",
        artifacts: { "failure_classification" => "git_failure" },
        failure_count: 1,
        finished_at: 10.minutes.ago
      )
      job.initial_run.update_columns(state: "failed", finished_at: 10.minutes.ago)

      active_workflow = Workflow.create!(
        job: job,
        trigger_kind: "auto_merge",
        state: "running",
        started_at: 1.minute.ago
      )
      active_step = Step.create!(
        workflow: active_workflow,
        kind: "grader",
        position: 0,
        state: "running",
        started_at: 1.minute.ago
      )
      active_run = Run.create!(
        job: job,
        step: active_step,
        trigger_kind: "auto_merge",
        state: "succeeded",
        started_at: 1.minute.ago,
        finished_at: 30.seconds.ago
      )
      active_run.update_columns(state: "running", finished_at: nil)

      expect(described_class.for(job.reload)).to include(
        classification: nil,
        classification_label: "Unclassified",
        retryable: false,
        state_label: "No failure"
      )
    end

    it "does not report an old failed workflow after a newer workflow succeeds" do
      job = Factories.job
      job.latest_workflow.update!(
        state: "failed",
        artifacts: { "failure_classification" => "git_failure" },
        failure_count: 1,
        finished_at: 10.minutes.ago
      )
      job.initial_run.update_columns(state: "failed", finished_at: 10.minutes.ago)

      succeeded_workflow = Workflow.create!(
        job: job,
        trigger_kind: "rebase",
        state: "succeeded",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )
      succeeded_step = Step.create!(
        workflow: succeeded_workflow,
        kind: "auto_rebase",
        position: 0,
        state: "succeeded",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )
      Run.create!(
        job: job,
        step: succeeded_step,
        trigger_kind: "rebase",
        state: "succeeded",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )

      expect(described_class.for(job.reload)).to include(
        classification: nil,
        classification_label: "Unclassified",
        retryable: false,
        state_label: "No failure"
      )
    end

    it "reports the latest failed workflow when it is still the current attempt" do
      job = Factories.job
      job.latest_workflow.update!(
        state: "failed",
        artifacts: { "failure_classification" => "git_failure" },
        failure_count: 1,
        finished_at: 1.minute.ago
      )
      job.initial_run.update_columns(state: "failed", finished_at: 1.minute.ago)

      expect(described_class.for(job.reload)).to include(
        classification: "git_failure",
        classification_label: "Git failure",
        retryable: true,
        state_label: "Retryable failure"
      )
    end

    it "does not report a failed workflow retryable while active WorkUnit ownership exists" do
      job = Factories.job
      job.latest_workflow.update!(
        state: "failed",
        artifacts: { "failure_classification" => "git_failure" },
        failure_count: 1,
        finished_at: 1.minute.ago
      )
      job.initial_run.update_columns(state: "failed", finished_at: 1.minute.ago)
      intent = WorkIntent.create!(
        kind: "chat_feedback",
        state: "requested",
        repository: job.repository,
        scope_type: "job",
        scope_id: job.id,
        actor: job.user,
        source_type: "spec"
      )
      unit = WorkUnit.create!(
        work_intent: intent,
        kind: "chat_feedback",
        state: "running",
        repository: job.repository,
        scope_type: "job",
        scope_id: job.id
      )
      unit.work_unit_members.create!(job: job, role: "primary")

      expect(described_class.for(job.reload)).to include(
        classification: "git_failure",
        classification_label: "Git failure",
        retryable: false,
        state_label: "Waiting for operator"
      )
    end

    it "does not call rebase-cap landing failures retryable" do
      job = Factories.job
      workflow = job.latest_workflow
      reason = 'Steps::Base::StepFailed: auto_merge: PR mergeable_state is "dirty" and rebase cap reached'

      job.update!(state: "implemented", landing_failure_reason: reason)
      workflow.update!(
        state: "failed",
        failure_reason: reason,
        artifacts: { "failure_reason" => reason },
        failure_count: 1,
        finished_at: 1.minute.ago
      )
      job.initial_run.update_columns(state: "failed", finished_at: 1.minute.ago)
      job.initial_run.create_run_diagnostic!(
        error_class: "Steps::Base::StepFailed",
        error_message: reason
      )

      expect(described_class.for(job.reload)).to include(
        classification: "non_retryable_failure",
        classification_label: "Non retryable failure",
        retryable: false,
        state_label: "Waiting for operator"
      )
    end
  end
end
