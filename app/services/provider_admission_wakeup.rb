class ProviderAdmissionWakeup
  Result = Data.define(:provider, :workflow_ids, :auto_retry_attempt_ids) do
    def workflow_count = workflow_ids.size
    def auto_retry_count = auto_retry_attempt_ids.size
    def as_json(*)
      {
        provider: provider,
        workflow_ids: workflow_ids,
        workflow_count: workflow_count,
        auto_retry_attempt_ids: auto_retry_attempt_ids,
        auto_retry_count: auto_retry_count
      }
    end
  end

  def self.call(provider:, user: nil)
    new(provider: provider, user: user).call
  end

  def self.preview(provider:, user: nil)
    new(provider: provider, user: user).preview
  end

  def initialize(provider:, user: nil)
    @provider = provider.to_s
    @user = user
  end

  def call
    return Result.new(provider: provider, workflow_ids: [], auto_retry_attempt_ids: []) if ProviderCircuitBreaker.call(provider).open?

    workflow_ids = wake_workflows
    auto_retry_attempt_ids = wake_auto_retries
    Result.new(provider: provider, workflow_ids: workflow_ids, auto_retry_attempt_ids: auto_retry_attempt_ids)
  end

  def preview
    Result.new(
      provider: provider,
      workflow_ids: workflows.map(&:id),
      auto_retry_attempt_ids: attempts.map(&:id)
    )
  end

  private

  attr_reader :provider, :user

  def wake_workflows
    workflows.map do |workflow|
      clear_provider_start_block!(workflow)
      StepDispatcher.start_workflow(workflow)
      workflow.id
    end
  end

  def workflows
    scope = Workflow
      .where(agent_provider: provider, state: "queued")
      .where.not(id: Workflow.joins(steps: :runs).select("workflows.id"))
      .order(:created_at, :id)
    scope = scope.where(user_id: user.id) if user
    scope.to_a
  end

  def wake_auto_retries
    attempts.map do |attempt|
      attempt.update!(skipped_reason: "provider circuit reopened; reconciler will retry immediately")
      WorkEngine::Reconciler.request(source: self.class.name, job: attempt.job)
      attempt.id
    end
  end

  def attempts
    scope = AutoRetryAttempt
      .includes(:job)
      .where(agent_provider: provider, performed_at: nil, skipped_reason: nil)
      .where("scheduled_at > ?", Time.current)
      .order(:scheduled_at, :id)
    scope = scope.joins(:job).where(jobs: { user_id: user.id }) if user
    scope.to_a
  end

  def clear_provider_start_block!(workflow)
    return unless workflow.artifact("start_blocked_reason").to_s.in?(%w[provider_circuit provider_usage_limit provider_availability])

    workflow.update!(
      artifacts: workflow.artifacts.to_h.except(
        "start_blocked_reason",
        "start_blocked_at",
        "start_blocked_last_seen_at",
        "start_blocked_next_check_at",
        "start_blocked_details",
        "pause_reason",
        "pause_kind",
        "pause_started_at",
        "pause_last_seen_at",
        "pause_next_check_at",
        "pause_details"
      )
    )
  end
end
