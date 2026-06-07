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
        state_label: "No failure",
        state_key: "none",
        tone: "gray"
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
        state_label: "No failure",
        state_key: "none",
        tone: "gray"
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
        state_label: "Retryable failure",
        state_key: "retryable",
        tone: "blue"
      )
    end

    it "reports exhausted retry state from auto-retry attempts" do
      job = Factories.job(agent_provider: "claude")
      workflow = job.latest_workflow
      run = job.initial_run
      workflow.update!(state: "failed", finished_at: 1.minute.ago)
      run.update_columns(state: "failed", finished_at: 1.minute.ago, agent_provider: "claude")
      run.create_run_failure_classification!(
        classification: "provider_transient",
        confidence: 0.8,
        retryable: true,
        reason: "The provider failed transiently.",
        classified_at: Time.current
      )
      AutoRetryScheduler::MAX_ATTEMPTS.times do |index|
        AutoRetryAttempt.create!(
          job: job,
          workflow: workflow,
          run: run,
          agent_provider: "claude",
          failure_classification: "provider_transient",
          retry_kind: "failed_step",
          attempt_number: index + 1,
          scheduled_at: Time.current
        )
      end

      expect(described_class.for(job.reload)).to include(
        classification: "provider_transient",
        classification_label: "Provider transient",
        retryable: false,
        retry_budget_remaining: 0,
        retry_budget: AutoRetryScheduler::MAX_ATTEMPTS,
        auto_retry_exhausted: true,
        state_label: "Auto-retry exhausted",
        state_key: "exhausted",
        tone: "red"
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
        classification: "operator_required",
        classification_label: "Operator intervention required",
        retryable: false,
        state_label: "Operator intervention required",
        state_key: "intervention_required",
        tone: "red"
      )
    end
  end
end
