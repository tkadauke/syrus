class ChatPendingAction < ApplicationRecord
  ACTIONS = %w[
    add_repo_note
    remove_repo_note
    cancel_job
    retry_job
    rebase_job
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

  def confirm!(user: nil)
    raise ActiveRecord::RecordNotFound, "pending action belongs to another user" if user && self.user != user

    with_lock do
      return false unless pending?

      record = nil
      ApplicationRecord.transaction do
        record = apply!
        updates = { state: "confirmed", confirmed_at: Time.current }
        updates[:result] = record if record
        update!(updates)
      end

      record || true
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
    when "cancel_job"
      action_job.cancel_active_runs_and_close!("cancelled")
    when "retry_job"
      job = action_job
      raise ArgumentError, "Thread is closed — use Start over to begin a new one." if job.closed?
      raise ArgumentError, "A Run is already in progress — wait for it to finish." if job.any_active_run?
      unless job.latest_workflow&.retry_as_new_workflow_available?
        raise ArgumentError, "Retry is not available for this Job."
      end

      job.sync_skip_prepare_from_source!
      workflow = Workflows::Retry.instantiate(job: job)
      StepDispatcher.start_workflow(workflow)
    when "rebase_job"
      job = action_job
      unless job.pr_number.present? || job.external_pr_number.present?
        raise ArgumentError, "No PR on this Job to rebase."
      end
      if job.workflows.active.where(trigger_kind: "rebase").exists?
        raise ArgumentError, "A rebase is already in progress — wait for it to finish."
      end

      workflow = Workflows::Rebase.instantiate(job: job)
      StepDispatcher.start_workflow(workflow)
    else
      RecurringTask.create!(
        user: user,
        repository: repository,
        cron_expression: payload.fetch("cron_expression"),
        label: payload.fetch("label"),
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
