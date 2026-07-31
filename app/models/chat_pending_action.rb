class ChatPendingAction < ApplicationRecord
  ACTIONS = %w[
    cancel_job
    close_job_successfully
    retry_job
    rebase_job
    reopen_job
    force_fail_job
    fire_scheduled_task_now
    create_repo_document
    delete_repo_document
    poll_job_feedback
    check_job_mergeability
    delegate_issue
    pause_landing_queue
    resume_landing_queue
    submit_chat_feedback
    complete_implement_step
    submit_coding_changes
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
    pause_landing_queue
    resume_landing_queue
  ].freeze
  STATES = %w[ queued pending confirmed rejected cancelled ].freeze
  REQUESTED_BY = %w[ agent operator ].freeze

  attribute :payload, :json, default: -> { {} }

  belongs_to :chat_session
  belongs_to :repository, optional: true
  belongs_to :user
  belongs_to :result, polymorphic: true, optional: true
  has_one :message, class_name: "ChatMessage", foreign_key: :pending_action_id, dependent: :nullify, inverse_of: :pending_action

  enum :state, STATES.index_with(&:itself), validate: true

  before_validation :derive_owner_from_chat_session
  after_create_commit :broadcast_pending_action_created
  after_update_commit :broadcast_pending_action_state_updated, if: :broadcastable_state_change?
  after_update_commit :notify_chat_of_outcome

  validates :action, inclusion: { in: ACTIONS }, allow_nil: true
  validates :action_type, inclusion: { in: ACTION_TYPES }, allow_nil: true
  validates :requested_by, presence: true, inclusion: { in: REQUESTED_BY }, if: :note_action?
  validates :payload, presence: true, unless: :empty_payload_action?
  validate :known_action
  validate :payload_matches_action
  validate :queued_actions_are_job_scoped
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

  def cancel!(user: nil)
    raise ActiveRecord::RecordNotFound, "pending action belongs to another user" if user && self.user != user
    return false unless pending? || queued?

    update!(state: "cancelled", cancelled_at: Time.current)
  end

  def promote!
    with_lock do
      return false unless queued?

      update!(state: "pending")
      broadcast_pending_action_updated
      true
    end
  end

  def self.promote_queued_for_job!(job)
    queued.where(repository_id: job.repository_id).find_each do |action|
      action.promote! if action.job_scoped_to?(job)
    end
  end

  def self.cancel_queued_for_job!(job)
    queued.where(repository_id: job.repository_id).find_each do |action|
      action.cancel! if action.job_scoped_to?(job)
    end
  end

  def job_scoped_to?(job)
    payload.to_h["job_id"].to_s == job.id.to_s
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

  # Each command object returns an AR record to stash on `action.result`
  # (polymorphic), or nil when the action is purely a mutation of
  # existing state. Anything else would blow up the polymorphic
  # assignment (which calls AR methods like `has_query_constraints?`
  # on the assigned object).
  def apply!
    PendingActions.for(action_key).new(self).execute
  end

  def known_action
    errors.add(:base, "unknown pending action") if action.blank? && action_type.blank?
  end

  def payload_matches_action
    PendingActions.for(action_key).new(self).validate_payload(errors)
  rescue PendingActions::UnknownAction
    # unknown actions are caught by known_action validation
  end

  def queued_actions_are_job_scoped
    errors.add(:payload, "job_id is required") if queued? && !payload.to_h["job_id"].present?
  end

  def repository_matches_chat_session
    return unless chat_session && repository
    return if chat_session.repository.nil?

    errors.add(:repository, "must match chat session") if repository_id != chat_session.repository_id
  end

  def user_matches_chat_session
    return unless chat_session && user
    errors.add(:user, "must match chat session") if user_id != chat_session.user_id
  end

  def notify_chat_of_outcome
    return unless saved_change_to_state?
    return unless confirmed? || rejected? || cancelled?

    text = ChatPendingActionOutcomeNotification.new(self).acknowledgment(outcome: state)
    message = chat_session.messages.create!(
      role: "system",
      content: { "text" => text, "source" => ChatPendingActionOutcomeNotification::SOURCE, "outcome" => state }
    )
    chat_session.update!(last_message_at: Time.current)
    chat_session.pin_chat_provider!
    ChatTurnJob.perform_later(chat_session_id, message.id)
  end

  def broadcastable_state_change?
    saved_change_to_state? && state.in?(%w[confirmed rejected cancelled])
  end

  def broadcast_pending_action_created
    broadcast_pending_action_updated
  end

  def broadcast_pending_action_state_updated
    broadcast_pending_action_updated
  end

  def broadcast_pending_action_updated
    AppEvents.broadcast(
      user: chat_session.user,
      type: "updated",
      resource: "chat",
      id: chat_session_id,
      changed: [ "pending_action_updated" ],
      payload: {
        action: "pending_action_updated",
        pending_action_id: id,
        chat_message_id: message&.id,
        state: state
      }
    )
  end
end
