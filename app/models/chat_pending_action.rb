class ChatPendingAction < ApplicationRecord
  ACTIONS = %w[
    add_repo_note
    remove_repo_note
    cancel_job
    retry_job
    rebase_job
    submit_chat_feedback
    reopen_epic_and_attach_job
    admin_kill_process
    admin_reap_stale_runs
    admin_pause_polling
    admin_unpause_polling
    admin_pause_runs
    admin_unpause_runs
    admin_clear_github_cache
    admin_pause_user_scheduling
    admin_unpause_user_scheduling
    admin_retry_step
    admin_cleanup_workspace
    admin_refresh_installations
  ].freeze
  ACTION_TYPES = %w[ schedule_recurring ].freeze
  EMPTY_PAYLOAD_ACTIONS = %w[
    admin_reap_stale_runs
    admin_pause_polling
    admin_unpause_polling
    admin_pause_runs
    admin_unpause_runs
    admin_clear_github_cache
    admin_refresh_installations
  ].freeze
  STATES = %w[ pending confirmed rejected cancelled ].freeze
  REQUESTED_BY = %w[ agent operator ].freeze

  attribute :payload, :json, default: -> { {} }

  belongs_to :chat_session
  belongs_to :repository
  belongs_to :user
  belongs_to :result, polymorphic: true, optional: true

  enum :state, STATES.index_with(&:itself), validate: true

  before_validation :derive_owner_from_chat_session

  validates :action, inclusion: { in: ACTIONS }, allow_nil: true
  validates :action_type, inclusion: { in: ACTION_TYPES }, allow_nil: true
  validates :requested_by, presence: true, inclusion: { in: REQUESTED_BY }, if: :note_action?
  validates :payload, presence: true, unless: :empty_payload_action?
  validate :known_action
  validate :payload_matches_action
  validate :repository_matches_chat_session
  validate :user_matches_chat_session

  # Returns true on successful confirmation, false when the action is
  # no longer pending. The thing that was created (if any) is available
  # as `action.result` after this returns — callers should consult that
  # rather than the boolean to drive UI messaging.
  def confirm!(user: nil)
    raise ActiveRecord::RecordNotFound, "pending action belongs to another user" if user && self.user != user

    with_lock do
      return false unless pending?

      ApplicationRecord.transaction do
        record = apply!
        updates = { state: "confirmed", confirmed_at: Time.current }
        updates[:result] = record if record
        update!(updates)
      end

      true
    end
  end

  def reject!
    with_lock do
      return false unless pending?

      update!(state: "rejected", rejected_at: Time.current)
    end
  end

  def cancel!(user:)
    raise ActiveRecord::RecordNotFound, "pending action belongs to another user" unless self.user == user
    return unless pending?

    update!(state: "cancelled", cancelled_at: Time.current)
  end

  private

  def derive_owner_from_chat_session
    return unless chat_session

    self.repository ||= chat_session.repository
    self.user ||= chat_session.user
  end

  def note_action?
    action.present?
  end

  def action_key
    action.presence || action_type
  end

  def empty_payload_action?
    EMPTY_PAYLOAD_ACTIONS.include?(action_key)
  end

  # Each branch returns an AR record to stash on `action.result`
  # (polymorphic), or nil when the action is purely a mutation of
  # existing state. Anything else would blow up the polymorphic
  # assignment (which calls AR methods like `has_query_constraints?`
  # on the assigned object).
  def apply!
    case action_key
    when "add_repo_note"
      chat_session.repository.repository_notes.create!(
        body: payload.fetch("body").to_s,
        author: "agent"
      )
    when "remove_repo_note"
      note = chat_session.repository.repository_notes.active.find(payload.fetch("id"))
      note.remove!
      nil
    when "cancel_job"
      action_job.cancel_active_runs_and_close!("cancelled")
      nil
    when "retry_job"
      job = action_job
      result = RetryWorkflowEnqueuer.call(job: job)
      raise ArgumentError, result.error unless result.success?

      nil
    when "rebase_job"
      job = action_job
      unless job.pr_number.present? || job.external_pr_number.present?
        raise ArgumentError, "No PR on this Job to rebase."
      end
      if RebaseWorkflowSelector.active_for_stack?(job)
        raise ArgumentError, "A rebase is already in progress — wait for it to finish."
      end

      workflow = RebaseWorkflowSelector.instantiate(job: job)
      StepDispatcher.start_workflow(workflow)
      nil
    when "submit_chat_feedback"
      job = action_job
      unless job.implemented? || job.approved?
        raise ArgumentError, "#{job.state} jobs are not actionable for chat feedback; the job must be implemented or approved."
      end
      if job.workflows.where(trigger_kind: "chat_feedback", state: %w[queued running]).exists?
        raise ArgumentError, "a chat_feedback workflow is already queued or running for this job"
      end

      workflow = Workflows::ChatFeedback.instantiate(
        job: job,
        artifacts: { "chat_feedback" => payload.fetch("feedback").to_s },
        agent_provider: job.agent_provider
      )
      StepDispatcher.start_workflow(workflow)
      job.reload.unapprove! if job.may_unapprove?
      workflow
    when "reopen_epic_and_attach_job"
      epic = repository.epics.where(user: user).find(payload.fetch("epic_id"))
      job = action_job

      epic.in_progress! if epic.done?
      job.update!(epic: epic, pending_epic_reference: {})
      job.advance_after_triage! if job.may_advance_after_triage?
      job
    when "admin_kill_process"
      process = SpawnedProcess.find(payload.fetch("process_id"))
      process.request_kill!(user: user) if process.running?
      nil
    when "admin_reap_stale_runs"
      ReapStaleRunsJob.perform_later
      nil
    when "admin_pause_polling"
      Admin::Console::Payload.new(actor: user).pause_polling(source: "chat_mcp")
      nil
    when "admin_unpause_polling"
      Admin::Console::Payload.new(actor: user).unpause_polling(source: "chat_mcp")
      nil
    when "admin_pause_runs"
      Admin::Console::Payload.new(actor: user).pause_runs(source: "chat_mcp")
      nil
    when "admin_unpause_runs"
      Admin::Console::Payload.new(actor: user).unpause_runs(source: "chat_mcp")
      nil
    when "admin_clear_github_cache"
      Admin::Console::Payload.new(actor: user).clear_github_cache(user_id: nil, source: "chat_mcp")
      nil
    when "admin_pause_user_scheduling"
      Admin::Users::Payload.new(params: {}, actor: user).pause_scheduling(payload.fetch("user_id"))
      nil
    when "admin_unpause_user_scheduling"
      Admin::Users::Payload.new(params: {}, actor: user).unpause_scheduling(payload.fetch("user_id"))
      nil
    when "admin_retry_step"
      workflow = Workflow.find(payload.fetch("workflow_id"))
      step_slug = payload.fetch("step_slug").to_s
      failed_step = RetryFailedStepEnqueuer.failed_step_for(workflow)
      unless failed_step&.kind == step_slug
        raise ArgumentError, "Step '#{step_slug}' is not the retryable failed step on #{workflow.slug}."
      end

      result = RetryFailedStepEnqueuer.call(workflow: workflow)
      raise ArgumentError, result.error unless result.success?

      result.run
    when "admin_cleanup_workspace"
      workflow = Workflow.find(payload.fetch("workflow_id"))
      raise ArgumentError, "Workflow workspace is still in use by active steps or runs." unless workflow.cleanup_workspace!

      nil
    when "admin_refresh_installations"
      SyncInstallationsJob.perform_later(user.id)
      nil
    else
      ScheduledTask.create!(
        user: user,
        repository: repository,
        kind: "cron",
        name: payload.fetch("label"),
        cron_expression: payload.fetch("cron_expression"),
        prompt: payload.fetch("prompt")
      )
    end
  end

  def known_action
    errors.add(:base, "unknown pending action") if action.blank? && action_type.blank?
  end

  def payload_matches_action
    case action_key
    when "add_repo_note"
      errors.add(:payload, "body is required") if payload["body"].to_s.strip.blank?
    when "remove_repo_note"
      errors.add(:payload, "id is required") unless payload["id"].present?
    when "cancel_job", "retry_job", "rebase_job"
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
    when "submit_chat_feedback"
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "feedback is required") if payload["feedback"].to_s.strip.blank?
    when "reopen_epic_and_attach_job"
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "epic_id is required") unless payload["epic_id"].present?
    when "admin_kill_process"
      errors.add(:payload, "process_id is required") unless payload["process_id"].present?
    when "admin_pause_user_scheduling", "admin_unpause_user_scheduling"
      errors.add(:payload, "user_id is required") unless payload["user_id"].present?
    when "admin_retry_step"
      errors.add(:payload, "workflow_id is required") unless payload["workflow_id"].present?
      errors.add(:payload, "step_slug is required") if payload["step_slug"].to_s.strip.blank?
    when "admin_cleanup_workspace"
      errors.add(:payload, "workflow_id is required") unless payload["workflow_id"].present?
    when "schedule_recurring"
      errors.add(:payload, "cron_expression is required") if payload["cron_expression"].to_s.strip.blank?
      errors.add(:payload, "label is required") if payload["label"].to_s.strip.blank?
      errors.add(:payload, "prompt is required") if payload["prompt"].to_s.strip.blank?
    end
  end

  def repository_matches_chat_session
    return unless chat_session && repository
    errors.add(:repository, "must match chat session") if repository_id != chat_session.repository_id
  end

  def user_matches_chat_session
    return unless chat_session && user
    errors.add(:user, "must match chat session") if user_id != chat_session.user_id
  end

  def action_job
    chat_session.repository.jobs.find(payload.fetch("job_id"))
  end
end
