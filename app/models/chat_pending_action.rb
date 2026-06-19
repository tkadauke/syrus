class ChatPendingAction < ApplicationRecord
  ACTIONS = %w[
    add_repo_note
    remove_repo_note
    cancel_job
    retry_job
    rebase_job
    submit_chat_feedback
    reopen_epic_and_attach_job
  ].freeze
  ACTION_TYPES = %w[ schedule_recurring ].freeze
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
  validates :payload, presence: true
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
