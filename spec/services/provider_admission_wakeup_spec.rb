require "rails_helper"

RSpec.describe ProviderAdmissionWakeup do
  include ActiveJob::TestHelper

  let(:job) { Factories.job(agent_provider: "claude") }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.first_step }
  let(:run) { step.runs.first }

  def fail_workflow!
    run.update_columns(state: "failed", agent_outcome: "worker_died", agent_provider: "claude", finished_at: Time.current)
    step.update_columns(state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current)
    job.update_columns(state: "failed")
  end

  def pending_attempt(scheduled_at: 10.minutes.from_now)
    fail_workflow!
    AutoRetryAttempt.create!(
      job: job,
      workflow: workflow,
      run: run,
      agent_provider: "claude",
      failure_classification: "worker_died",
      retry_kind: "retry_workflow",
      attempt_number: 1,
      scheduled_at: scheduled_at
    )
  end

  def closed_circuit
    ProviderCircuitBreaker::Decision.new(
      provider: "claude",
      open: false,
      reason: "provider healthy",
      retry_after: nil,
      failure_count: 0,
      job_count: 0,
      signature: nil
    )
  end

  def open_circuit
    ProviderCircuitBreaker::Decision.new(
      provider: "claude",
      open: true,
      reason: "provider degraded",
      retry_after: 30.minutes.from_now,
      failure_count: 5,
      job_count: 3,
      signature: nil
    )
  end

  def blocked_workflow(user:, repository:, provider_account:)
    queued_job = Factories.job_record(user: user, repository: repository, agent_provider: "claude", state: "queued")
    WorkUnits::Launcher.instantiate(kind: "initial", job: queued_job).tap do |queued_workflow|
      queued_workflow.update!(agent_provider: "claude", provider_account: provider_account)
      queued_workflow.work_unit.update!(
        state: "blocked",
        blocked_reason: WorkUnits::Gates::ProviderAvailability::REASON
      )
    end
  end

  describe ".call" do
    it "cancels future-scheduled auto-retry attempts and requests a reconcile for each affected job" do
      attempt = pending_attempt
      allow(ProviderCircuitBreaker).to receive(:call).and_return(closed_circuit)

      expect {
        described_class.call(provider: "claude")
      }.to have_enqueued_job(WorkEngine::ReconcileJob).with(
        source: "ProviderAdmissionWakeup",
        job_id: job.id,
        workflow_id: nil,
        run_id: nil
      )

      expect(attempt.reload.skipped_reason).to eq("provider circuit reopened; reconciler will retry immediately")
      expect(attempt.performed_at).to be_nil
    end

    it "returns a result with the woken attempt ids" do
      attempt = pending_attempt
      allow(ProviderCircuitBreaker).to receive(:call).and_return(closed_circuit)

      result = described_class.call(provider: "claude")

      expect(result.auto_retry_attempt_ids).to eq([ attempt.id ])
      expect(result.provider).to eq("claude")
    end

    it "wakes provider-blocked queued workflows through the work unit launcher" do
      queued_job = Factories.job_record(user: job.user, repository: job.repository, agent_provider: "claude", state: "queued")
      queued_workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: queued_job)
      queued_workflow.update!(
        agent_provider: "claude",
        artifacts: {
          "start_blocked_reason" => StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON,
          "pause_reason" => StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON
        }
      )
      queued_workflow.work_unit.update!(
        state: "blocked",
        blocked_reason: WorkUnits::Gates::ProviderAvailability::REASON
      )
      allow(ProviderCircuitBreaker).to receive(:call).and_return(closed_circuit)

      expect(WorkUnits::Launcher).to receive(:start!).with(queued_workflow).once.and_call_original

      result = described_class.call(provider: "claude")

      expect(result.workflow_ids).to eq([ queued_workflow.id ])
      expect(queued_workflow.reload.artifact("start_blocked_reason")).to be_nil
      expect(queued_workflow.first_step.runs.count).to eq(1)
    end

    it "does not wake stale legacy landing workflows" do
      legacy_job = Factories.job_record(user: job.user, repository: job.repository, agent_provider: "claude", state: "landing")
      legacy_workflow = Workflow.create!(
        job: legacy_job,
        trigger_kind: "auto_merge",
        agent_provider: "claude",
        state: "queued",
        artifacts: {
          "start_blocked_reason" => StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON,
          "pause_reason" => StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON
        }
      )
      queued_job = Factories.job_record(user: job.user, repository: job.repository, agent_provider: "claude", state: "landing")
      queued_workflow = WorkUnits::Launcher.instantiate(kind: "auto_merge", job: queued_job)
      queued_workflow.update!(
        agent_provider: "claude",
        artifacts: {
          "start_blocked_reason" => StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON,
          "pause_reason" => StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON
        }
      )
      queued_workflow.work_unit.block!(reason: WorkUnits::Gates::ProviderAvailability::REASON)
      allow(ProviderCircuitBreaker).to receive(:call).and_return(closed_circuit)

      result = described_class.call(provider: "claude")

      expect(result.workflow_ids).to eq([ queued_workflow.id ])
      expect(legacy_workflow.reload.steps).to be_empty
      expect(queued_workflow.reload.first_step.runs.count).to eq(1)
    end

    it "is a no-op when the provider circuit is still open" do
      pending_attempt
      allow(ProviderCircuitBreaker).to receive(:call).and_return(open_circuit)

      expect {
        described_class.call(provider: "claude")
      }.not_to have_enqueued_job(WorkEngine::ReconcileJob)
    end

    it "wakes only workflows whose user and pinned account circuit is closed" do
      first_user = Factories.user(claude_oauth_token: "first-token")
      first_repository = Factories.repository(user: first_user)
      first_account = first_user.default_provider_account("claude")
      sibling_account = ProviderAccount.create!(
        user: first_user,
        provider_key: "claude",
        authentication_kind: "claude_oauth_token",
        credential_payload: { "claude_oauth_token" => "sibling-token" },
        position: 1
      )
      second_user = Factories.user(claude_oauth_token: "second-user-token")
      second_account = second_user.default_provider_account("claude")
      blocked = blocked_workflow(user: first_user, repository: first_repository, provider_account: first_account)
      healthy_sibling = blocked_workflow(user: first_user, repository: first_repository, provider_account: sibling_account)
      healthy_other_user = blocked_workflow(
        user: second_user,
        repository: Factories.repository(user: second_user),
        provider_account: second_account
      )
      allow(ProviderCircuitBreaker).to receive(:call) do |_, user:, provider_account:, **|
        user == first_user && provider_account == first_account ? open_circuit : closed_circuit
      end

      result = described_class.call(provider: "claude")

      expect(result.workflow_ids).to contain_exactly(healthy_sibling.id, healthy_other_user.id)
      expect(blocked.reload.work_unit).to be_blocked
      expect(healthy_sibling.reload.work_unit).not_to be_blocked
      expect(healthy_other_user.reload.work_unit).not_to be_blocked
    end

    it "wakes only auto retries whose pinned account circuit is closed" do
      user = Factories.user(claude_oauth_token: "first-token")
      repository = Factories.repository(user: user)
      first_account = user.default_provider_account("claude")
      sibling_account = ProviderAccount.create!(
        user: user,
        provider_key: "claude",
        authentication_kind: "claude_oauth_token",
        credential_payload: { "claude_oauth_token" => "sibling-token" },
        position: 1
      )
      build_attempt = lambda do |account, issue_number|
        retry_job = Factories.job(repository: repository, issue_number: issue_number, agent_provider: "claude")
        retry_workflow = retry_job.latest_workflow
        retry_run = retry_job.initial_run
        retry_workflow.update_columns(state: "failed", provider_account_id: account.id, finished_at: Time.current)
        retry_run.update_columns(state: "failed", provider_account_id: account.id, finished_at: Time.current)
        retry_job.update_columns(state: "failed")
        AutoRetryAttempt.create!(
          job: retry_job,
          workflow: retry_workflow,
          run: retry_run,
          agent_provider: "claude",
          failure_classification: "worker_died",
          retry_kind: "retry_workflow",
          attempt_number: 1,
          scheduled_at: 10.minutes.from_now
        )
      end
      blocked = build_attempt.call(first_account, 81)
      healthy = build_attempt.call(sibling_account, 82)
      allow(ProviderCircuitBreaker).to receive(:call) do |_, provider_account:, **|
        provider_account == first_account ? open_circuit : closed_circuit
      end

      result = described_class.call(provider: "claude", user: user)

      expect(result.auto_retry_attempt_ids).to eq([ healthy.id ])
      expect(blocked.reload.skipped_reason).to be_nil
      expect(healthy.reload.skipped_reason).to eq("provider circuit reopened; reconciler will retry immediately")
    end

    it "ignores already-performed or skipped attempts" do
      attempt = pending_attempt
      attempt.update!(performed_at: Time.current)
      allow(ProviderCircuitBreaker).to receive(:call).and_return(closed_circuit)

      expect {
        described_class.call(provider: "claude")
      }.not_to have_enqueued_job(WorkEngine::ReconcileJob)
    end

    it "ignores past-due attempts (scheduled in the past)" do
      attempt = pending_attempt(scheduled_at: 5.minutes.ago)
      allow(ProviderCircuitBreaker).to receive(:call).and_return(closed_circuit)

      expect {
        described_class.call(provider: "claude")
      }.not_to have_enqueued_job(WorkEngine::ReconcileJob)

      expect(attempt.reload.skipped_reason).to be_nil
    end
  end

  describe ".preview" do
    it "returns the attempt ids without side effects" do
      attempt = pending_attempt
      allow(ProviderCircuitBreaker).to receive(:call).and_return(closed_circuit)

      expect {
        result = described_class.preview(provider: "claude")
        expect(result.auto_retry_attempt_ids).to eq([ attempt.id ])
      }.not_to have_enqueued_job(WorkEngine::ReconcileJob)

      expect(attempt.reload.skipped_reason).to be_nil
    end
  end
end
