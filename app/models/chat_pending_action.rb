class ChatPendingAction < ApplicationRecord
  include PendingActions::Invocation

  TOOL_CALL_ANCHOR_REPAIR_SCAN_LIMIT = 250
  TOOL_CALL_ANCHOR_REPAIR_MAX_AGE = 1.day

  attr_accessor :suppress_outcome_notification

  ACTIONS = %w[
    cancel_job
    close_job_successfully
    retry_job
    base_refresh_retry_job
    rebase_job
    force_rebase
    restack_epic
    archive_epic
    reopen_job
    approve_job
    unapprove_job
    force_fail_job
    fire_scheduled_task_now
    create_repo_document
    create_coworker
    escalate_coworker_grants
    delete_repo_document
    delete_design_doc
    poll_job_feedback
    run_visual_review
    check_job_mergeability
    delegate_issue
    pause_landing_queue
    resume_landing_queue
    submit_chat_feedback
    complete_implement_step
    emergency_land
    submit_coding_changes
    reopen_epic_and_attach_job
    admin_kill_process
    admin_mysql_kill_query
    admin_reap_stale_runs
    admin_pause_polling
    admin_unpause_polling
    admin_pause_runs
    admin_unpause_runs
    admin_clear_github_cache
    admin_maintenance_task
    admin_pause_user_scheduling
    admin_unpause_user_scheduling
    admin_retry_step
    admin_cleanup_workspace
    admin_refresh_installations
    reconcile_job_state
    force_state_transition
    cancel_stale_work
    reenqueue_work
    repair_queue_affinity
    force_landing_recheck
    manual_agentic_run
    adopt_current_pr_head
    replace_pr_branch_with_workflow_output
    retry_from_current_pr_branch
    rerun_ci_repair
    retire_terminal_work_unit
    mark_ci_repair_noop
    override_landing_blocker_once
    wake_landing_queue
    repair_provider_circuit_evidence
    clear_provider_circuit
    wake_provider_admission
    mutate_provider_routing_rules
    grant_permission
    deny_permission
    revoke_permission
    create_permission_lease
    revoke_permission_lease
    apply_permission_preset
    cancel_authorization_request
    override_job_planned_execution
    local_tool_call
    coworker_tool_call
    spawn_chat
    accept_insights
    dismiss_insights
    retire_insights
  ].freeze
  ACTION_TYPES = %w[ schedule_recurring ].freeze
  # Actions whose payload["job_id"] should resolve to a target Job resource
  # link on pending-action cards. Single source of truth for both
  # App::ChatMessagePayload (message-anchored pending actions) and
  # ChatSerialization (the live/unanchored pending-actions list) so the two
  # surfaces can't drift out of sync again (see App::Presentation's
  # pending_action_label/detail comment for the earlier incident this
  # pattern is modeled on).
  JOB_RESOURCE_ACTIONS = %w[
    cancel_job
    close_job_successfully
    retry_job
    base_refresh_retry_job
    force_fail_job
    override_job_planned_execution
    rebase_job
    force_rebase
    reopen_job
    poll_job_feedback
    run_visual_review
    check_job_mergeability
    submit_chat_feedback
    force_landing_recheck
    override_landing_blocker_once
    complete_implement_step
    emergency_land
    manual_agentic_run
    adopt_current_pr_head
    replace_pr_branch_with_workflow_output
    retry_from_current_pr_branch
    reconcile_job_state
    force_state_transition
    cancel_stale_work
    reenqueue_work
    repair_queue_affinity
    rerun_ci_repair
    mark_ci_repair_noop
  ].freeze
  EPIC_RESOURCE_ACTIONS = %w[
    restack_epic
    archive_epic
  ].freeze
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
  STATES = %w[ queued pending confirming confirmed rejected cancelled failed dismissed non_actionable ].freeze
  REQUEST_KINDS = %w[ legacy_action authorization_request ].freeze
  REQUESTED_BY = %w[ agent operator ].freeze
  CONFIRMED_VISIBLE_FOR = 1.second

  attribute :payload, :json, default: -> { {} }
  attribute :before_snapshot, :json, default: -> { {} }
  attribute :after_snapshot, :json, default: -> { {} }
  attribute :delivery_metadata, :json, default: -> { {} }

  belongs_to :chat_session, optional: true
  belongs_to :repository, optional: true
  belongs_to :user
  belongs_to :origin, polymorphic: true, optional: true
  belongs_to :subject, polymorphic: true, optional: true
  belongs_to :result, polymorphic: true, optional: true
  belongs_to :tool_call_message, class_name: "ChatMessage", foreign_key: :chat_message_id, optional: true
  belongs_to :pending_action_group, optional: true, inverse_of: :chat_pending_actions
  has_one :message, class_name: "ChatMessage", foreign_key: :pending_action_id, dependent: :nullify, inverse_of: :pending_action
  has_many :authorization_items, class_name: "PendingActionItem", dependent: :destroy, inverse_of: :chat_pending_action
  has_many :transitions, class_name: "PendingActionTransition", dependent: :delete_all, inverse_of: :chat_pending_action

  enum :state, STATES.index_with(&:itself), validate: true

  before_validation :derive_owner_from_chat_session
  before_validation :derive_origin_from_chat_session
  before_validation :activate_authorization_deduplication
  before_update :release_terminal_deduplication, if: :will_save_change_to_state?
  after_create :record_creation_transition!
  after_update :capture_outcome_transition, if: :saved_change_to_state?
  after_update :record_state_transition!, if: :saved_change_to_state?
  after_rollback :clear_outcome_transition
  after_create_commit :broadcast_pending_action_created
  after_update_commit :broadcast_pending_action_state_updated, if: :broadcastable_state_change?
  after_update_commit :notify_chat_of_outcome

  validates :action, inclusion: { in: ACTIONS }, allow_nil: true
  validates :action_type, inclusion: { in: ACTION_TYPES }, allow_nil: true
  validates :request_kind, inclusion: { in: REQUEST_KINDS }
  validates :requested_by, presence: true, inclusion: { in: REQUESTED_BY }, if: :note_action?
  validates :payload, presence: true, if: -> { legacy_action? && !empty_payload_action? }
  validates :origin, :subject, presence: true, if: :authorization_request?
  validate :known_action, if: :legacy_action?
  validate :payload_matches_action, if: :legacy_action?
  validate :queued_actions_are_job_scoped, if: :legacy_action?
  validate :repository_matches_chat_session
  validate :user_matches_chat_session

  scope :actionable, -> { where(deduplication_active: true, non_actionable_at: nil) }

  def self.find_equivalent(deduplication_key)
    return if deduplication_key.blank?

    actionable.find_by(deduplication_key: deduplication_key)
  end

  def self.create_or_find_authorization_request!(attributes)
    create!(attributes.merge(request_kind: "authorization_request"))
  rescue ActiveRecord::RecordNotUnique
    find_equivalent(attributes[:deduplication_key] || attributes["deduplication_key"]) || raise
  end

  def legacy_action?
    request_kind == "legacy_action"
  end

  def authorization_request?
    request_kind == "authorization_request"
  end

  def actionable?
    non_actionable_at.nil? && !dismissed? && !non_actionable?
  end

  def ready_for_authorized_invocation?
    authorization_request? && authorization_items.exists? && authorization_items.where.not(state: "approved").none?
  end

  def mark_non_actionable!(reason)
    with_lock do
      return false unless actionable?

      authorization_items.pending.find_each { |item| item.mark_non_actionable!(reason) }
      update!(state: "non_actionable", non_actionable_at: Time.current, non_actionable_reason: reason)
    end
    true
  end

  def dismiss!
    with_lock do
      return false unless state.in?(%w[pending non_actionable failed])

      update!(state: "dismissed")
    end
    true
  end

  def record_delivery!(metadata: {}, at: Time.current)
    update!(
      delivery_state: "delivered",
      delivered_at: at,
      delivery_attempts: delivery_attempts + 1,
      last_delivery_error: nil,
      delivery_metadata: delivery_metadata.to_h.merge(metadata.to_h.stringify_keys)
    )
  end

  def record_delivery_failure!(error, metadata: {})
    update!(
      delivery_state: "failed",
      delivery_attempts: delivery_attempts + 1,
      last_delivery_error: "#{error.class}: #{error.message}",
      delivery_metadata: delivery_metadata.to_h.merge(metadata.to_h.stringify_keys)
    )
  end

  def confirm!(user: nil)
    return false unless start_confirmation!(
      user: user,
      status: "running",
      step: "Starting pending action..."
    )

    execute_confirmation!(raise_on_error: true)
  end

  def enqueue_confirmation!(user: nil)
    return false unless start_confirmation!(
      user: user,
      status: "queued",
      step: "Waiting for background worker..."
    )

    ChatPendingActionConfirmationJob.perform_later(id)
    true
  end

  def start_confirmation!(user: nil, status:, step:)
    raise ActiveRecord::RecordNotFound, "pending action belongs to another user" if user && self.user != user

    with_lock do
      return false unless pending?

      raise ActiveRecord::RecordInvalid, self unless valid?
      update!(
        state: "confirming",
        execution_status: status,
        execution_step: step,
        execution_error: nil,
        execution_started_at: nil,
        execution_finished_at: nil
      )
      true
    end
  end

  def execute_confirmation!(raise_on_error: false, finalize: true)
    should_execute = with_lock do
      return false unless confirming?
      return false if !finalize && execution_status == "running"

      update_confirmation_progress!("running", "Starting pending action...")
      true
    end
    return false unless should_execute

    raise ActiveRecord::RecordInvalid, self unless valid?

    command = PendingActions.for(action_key).new(self)
    command.authorize_execution!
    repair_targets = command.repair_snapshot_targets
    if command.repair_action?
      ApplicationRecord.transaction do
        update_confirmation_progress!("running", "Capturing before snapshot...")
        update!(before_snapshot: PendingActions::RepairAuditSnapshot.capture(repair_targets))
        record_repair_admin_action!(nil, outcome: "prepared", intent: true)
      end
    end

    ApplicationRecord.transaction do
      update_confirmation_progress!("running", command.execution_label)
    end
    record = command.execute
    return true if record.equal?(PendingActions::Base::DEFERRED_CONFIRMATION)

    if command.repair_action?
      begin
        ApplicationRecord.transaction do
          update_confirmation_progress!("running", "Capturing after snapshot...")
          update!(after_snapshot: PendingActions::RepairAuditSnapshot.capture(repair_targets))
        end
      rescue StandardError => e
        return complete_repair_with_audit_failure!(record, e, finalize: finalize)
      end
    end

    ApplicationRecord.transaction do
      if command.repair_action?
        repair_outcome = command.confirmation_outcome.presence || (before_snapshot == after_snapshot ? "noop" : "applied")
        begin
          record_repair_admin_action!(record, outcome: repair_outcome)
        rescue StandardError => e
          return complete_repair_with_audit_failure!(record, e, finalize: finalize)
        end
      else
        repair_outcome = "applied"
      end
      if finalize
        complete_confirmation!(record, outcome: repair_outcome,
          step: repair_outcome == "applied" ? "Applied." : repair_outcome.to_s.humanize + ".")
      else
        updates = {
          execution_status: "waiting", execution_step: "Waiting for refresh workflow to finish...",
          execution_error: nil
        }
        updates[:result] = record if record
        update!(updates)
      end
    end
    true
  rescue StandardError => e
    fail_confirmation!(e)
    raise if raise_on_error

    false
  end

  def complete_confirmation!(record = nil, outcome: "applied", step: "Applied.")
    updates = {
      state: "confirmed",
      confirmed_at: Time.current,
      execution_status: outcome,
      execution_step: step,
      execution_error: nil,
      execution_finished_at: Time.current
    }
    updates[:result] = record if record
    update!(updates)
  end

  def complete_sequenced_confirmation!
    complete_confirmation!(outcome: "applied", step: "Refresh workflow succeeded.")
  end

  def update_confirmation_progress!(status, step)
    update!(
      execution_status: status,
      execution_step: step,
      execution_started_at: execution_started_at || Time.current
    )
  end

  def fail_confirmation!(error)
    rejected = error.is_a?(RepairEligibility::Ineligible)
    update!(
      state: "failed",
      execution_status: rejected ? "rejected" : "failed",
      execution_step: rejected ? "Rejected after eligibility revalidation." : "Failed.",
      execution_error: "#{error.class}: #{error.message}",
      execution_finished_at: Time.current
    )
  end

  def reject!(user: nil)
    raise ActiveRecord::RecordNotFound, "pending action belongs to another user" if user && self.user != user

    with_lock do
      return false unless pending?

      update!(state: "rejected", rejected_at: Time.current)
    end
  end

  def cancel!(user: nil)
    raise ActiveRecord::RecordNotFound, "pending action belongs to another user" if user && self.user != user
    return false unless pending? || queued? || failed?

    update!(state: "cancelled", cancelled_at: Time.current)
  end

  def visible_in_chat_payload?
    queued? || pending? || confirming? || failed? || recently_confirmed?
  end

  def group_outcome
    return "skipped" if execution_status.in?(%w[noop rejected skipped no_longer_eligible]) || rejected? || cancelled?
    return "failed" if execution_status == "partial" || failed?
    return "applied" if confirmed?

    nil
  end

  def recently_confirmed?
    confirmed? && confirmed_at.present? && confirmed_at >= CONFIRMED_VISIBLE_FOR.ago
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

  def anchor_message
    tool_call_message || message
  end

  def self.anchor_to_tool_call!(chat_session:, pending_action_id:, tool_use_id:)
    return if pending_action_id.blank? || tool_use_id.blank?

    pending_action = chat_session.pending_actions.find_by(id: pending_action_id)
    tool_message = chat_session.messages.find_by(role: "tool_use", tool_use_id: tool_use_id.to_s)
    return unless pending_action && tool_message

    ChatMessage.transaction do
      pending_action.update_columns(chat_message_id: tool_message.id, tool_use_id: tool_use_id.to_s, updated_at: Time.current)
      chat_session.messages
        .where(pending_action_id: pending_action.id)
        .where.not(id: tool_message.id)
        .update_all(pending_action_id: nil)
      tool_message.update_columns(pending_action_id: pending_action.id)
    end

    pending_action
  end

  def self.pending_action_id_from_tool_result(tool_result_content)
    parsed = pending_action_tool_result_hash(tool_result_content)
    return unless parsed.is_a?(Hash)

    parsed&.fetch("pending_action_id", nil) ||
      parsed&.fetch(:pending_action_id, nil) ||
      parsed&.fetch("pending_confirmation_id", nil) ||
      parsed&.fetch(:pending_confirmation_id, nil)
  end

  def self.repair_tool_call_anchors_for!(chat_session)
    # Match visible_in_chat_payload?'s state set (minus confirmed, which is
    # only visible for a fleeting second and not worth repairing for): a
    # pending action can transition from pending to confirming to failed
    # before this repair ever runs, and if it was never anchored to its
    # originating tool call it must not fall out of scope just because it
    # is no longer queued/pending -- that's what left failed actions
    # permanently stuck at the bottom of the chat instead of anchored to
    # the tool call that created them.
    unanchored_actions = chat_session.pending_actions
      .where(state: %w[queued pending confirming failed], chat_message_id: nil)
      .select(:id, :chat_session_id, :tool_use_id, :created_at)
      .to_a
    return if unanchored_actions.blank?

    unanchored_actions.select { |action| action.tool_use_id.present? }.each do |action|
      anchor_to_tool_call!(
        chat_session: chat_session,
        pending_action_id: action.id,
        tool_use_id: action.tool_use_id
      )
    end

    legacy_unanchored_ids = unanchored_actions
      .select { |action| action.tool_use_id.blank? && action.created_at >= TOOL_CALL_ANCHOR_REPAIR_MAX_AGE.ago }
      .map(&:id)
    return if legacy_unanchored_ids.blank?

    chat_session.messages
      .where(role: "tool_result")
      .where.not(tool_use_id: [ nil, "" ])
      .reorder(id: :desc)
      .limit(TOOL_CALL_ANCHOR_REPAIR_SCAN_LIMIT)
      .to_a
      .reverse_each do |message|
        pending_action_id = pending_action_id_from_tool_result(tool_result_payload(message))
        next unless legacy_unanchored_ids.include?(pending_action_id.to_i)

        anchor_to_tool_call!(
          chat_session: chat_session,
          pending_action_id: pending_action_id,
          tool_use_id: message.tool_use_id
        )
      end
  end

  private

  def self.tool_result_payload(message)
    if message.content.is_a?(Hash) && message.content["type"] == "tool_result"
      message.content["content"] || message.content["result"]
    else
      message.content
    end
  end

  def self.pending_action_tool_result_hash(tool_result_content)
    case tool_result_content
    when Hash
      tool_result_content
    when String
      JSON.parse(tool_result_content)
    when Array
      text = tool_result_content
        .find { |block| block.is_a?(Hash) && (block["type"] || block[:type]) == "text" }
        &.then { |block| block["text"] || block[:text] }
      text.present? ? JSON.parse(text) : nil
    end
  rescue JSON::ParserError, TypeError
    nil
  end

  def derive_owner_from_chat_session
    return unless chat_session

    self.repository ||= chat_session.repository
    self.user ||= chat_session.user
  end

  def derive_origin_from_chat_session
    self.origin ||= chat_session
  end

  def activate_authorization_deduplication
    self.deduplication_active = true if authorization_request? && deduplication_key.present? && deduplication_active.nil? && actionable?
  end

  def release_terminal_deduplication
    self.deduplication_active = nil if state.in?(%w[confirmed rejected cancelled failed dismissed non_actionable])
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

  def known_action
    errors.add(:base, :unknown_pending_action) if action.blank? && action_type.blank?
  end

  def payload_matches_action
    PendingActions.for(action_key).new(self).validate_payload(errors)
  rescue PendingActions::UnknownAction
    # unknown actions are caught by known_action validation
  end

  def record_repair_admin_action!(record, outcome:, intent: false)
    AdminAction.log!(
      user: user,
      action: "#{intent ? 'repair_intent' : 'repair'}_#{action_key}",
      params: PendingActions::RepairAuditPayload.build(pending_action: self, record: record, outcome: outcome)
    )
  end

  def complete_repair_with_audit_failure!(record, error, finalize:)
    Rails.logger.error("[ChatPendingAction] repair applied but final audit persistence failed pending_action_id=#{id}: #{error.class}: #{error.message}")
    return true unless finalize

    complete_confirmation!(record, outcome: "partial", step: "Repair applied; final audit evidence could not be persisted.")
    true
  end

  def repair_result_payload(record)
    return nil unless record

    {
      type: record.class.name,
      id: record.id
    }
  end

  def queued_actions_are_job_scoped
    errors.add(:payload, :job_id_required) if queued? && !payload.to_h["job_id"].present?
  end

  def repository_matches_chat_session
    return unless chat_session && repository
    return if chat_session.repository.nil?

    errors.add(:repository, :chat_session_mismatch) if repository_id != chat_session.repository_id
  end

  def user_matches_chat_session
    return unless chat_session && user
    errors.add(:user, :chat_session_mismatch) if user_id != chat_session.user_id
  end

  def notify_chat_of_outcome
    return unless chat_session
    return if suppress_outcome_notification
    return unless @outcome_state_to_notify

    outcome = @outcome_state_to_notify
    text = ChatPendingActionOutcomeNotification.new(self).acknowledgment(outcome: outcome)
    message = chat_session.messages.create!(
      role: "system",
      content: { "text" => text, "source" => ChatPendingActionOutcomeNotification::SOURCE, "outcome" => outcome }
    )
    chat_session.update!(last_message_at: Time.current)
    chat_session.pin_chat_provider!
    ChatTurnJob.perform_later(chat_session_id, message.id)
  ensure
    @outcome_state_to_notify = nil
  end

  # Creating the append-only transition row takes a lock on this record. That
  # reloads it before the commit callbacks run and clears Active Record's
  # saved-change tracking, so a commit guard based on saved_change_to_state?
  # silently misses the outcome. Capture the terminal transition before the
  # audit callback and consume it exactly once after commit instead.
  def capture_outcome_transition
    new_state = saved_change_to_state&.last
    return unless new_state.in?(%w[confirmed rejected cancelled])

    @outcome_state_to_notify = new_state
    @outcome_state_to_broadcast = new_state
  end

  def clear_outcome_transition
    @outcome_state_to_notify = nil
    @outcome_state_to_broadcast = nil
  end

  def broadcastable_state_change?
    return true if @outcome_state_to_broadcast
    return true if saved_change_to_state? && state.in?(%w[confirming confirmed rejected cancelled failed])

    saved_change_to_execution_status? || saved_change_to_execution_step? || saved_change_to_execution_error?
  end

  def broadcast_pending_action_created
    broadcast_pending_action_updated
  end

  def broadcast_pending_action_state_updated
    broadcast_pending_action_updated
  ensure
    @outcome_state_to_broadcast = nil
  end

  def broadcast_pending_action_updated
    return unless chat_session

    AppEvents.broadcast(
      user: chat_session.user,
      type: "updated",
      resource: "chat",
      id: chat_session_id,
      changed: [ "pending_action_updated" ],
      payload: {
        action: "pending_action_updated",
        pending_action_id: id,
        chat_message_id: anchor_message&.id,
        state: state,
        execution_status: execution_status,
        execution_step: execution_step,
        execution_error: execution_error
      }
    )
  end

  def record_creation_transition!
    transitions.create!(event_type: "created", to_state: state, metadata: {})
  end

  def record_state_transition!
    from, to = saved_change_to_state
    transitions.create!(event_type: "state_changed", from_state: from, to_state: to, metadata: {})
  end
end
