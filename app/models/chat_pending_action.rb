class ChatPendingAction < ApplicationRecord
  ACTIONS = %w[
    add_repo_note
    remove_repo_note
    cancel_job
    retry_job
    rebase_job
    reopen_job
    fire_scheduled_task_now
    create_repo_document
    delete_repo_document
    poll_job_feedback
    check_job_mergeability
    delegate_issue
    pause_landing_queue
    resume_landing_queue
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
    when "reopen_job"
      job = action_user_job
      raise ArgumentError, "Job isn't closed." unless job.may_reopen?

      job.reopen!
      job.save!
      job
    when "fire_scheduled_task_now"
      task = action_scheduled_task
      raise ArgumentError, "Task isn't fireable in its current state." if task.archived? || task.fired?

      result = ScheduledTaskFire.new(task).call
      result.fired? ? result.job : nil
    when "create_repo_document"
      repo = action_user_repository
      document = repo.repository_documents.new(
        user: user,
        kind: "file",
        title: payload.fetch("title").to_s
      )
      document.file.attach(
        io: StringIO.new(payload.fetch("body").to_s),
        filename: document_filename(document.title),
        content_type: "text/markdown"
      )
      document.save!
      document
    when "delete_repo_document"
      document = action_user_document
      document.file.purge if document.file.attached?
      document.destroy!
      nil
    when "poll_job_feedback"
      job = action_user_job
      unless job.open? && job.pr_number.present?
        raise ArgumentError, "Can only check feedback on open Jobs that have a PR."
      end

      PollPullRequestJob.perform_later(job.id, manual: true)
      nil
    when "check_job_mergeability"
      job = action_user_job
      unless job.pr_number.present? || job.external_pr_number.present?
        raise ArgumentError, "No PR on this Job to check."
      end

      PollRebaseJob.perform_later(job.id, bypass_cache: true)
      nil
    when "delegate_issue"
      repo = action_user_repository
      issue_number = Integer(payload.fetch("issue_number"), exception: false)
      raise ArgumentError, "issue_number is required" unless issue_number&.positive?

      GithubClient.for(repository: repo, user: user).add_label_to_issue(repo.slug, issue_number, repo.trigger_label)
      nil
    when "pause_landing_queue"
      user.update!(landing_paused: true)
      nil
    when "resume_landing_queue"
      user.update!(landing_paused: false)
      LandingQueueProcessorJob.perform_later
      nil
    when "submit_chat_feedback"
      job = action_job
      result = ChatFeedbackSubmission.call(
        job: job,
        feedback: payload.fetch("feedback"),
        allowed_states: %w[implemented approved]
      )
      raise ArgumentError, result.error unless result.success?

      result.workflow
    when "reopen_epic_and_attach_job"
      epic = self.repository.epics.where(user: user).find(payload.fetch("epic_id"))
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
        repository: self.repository,
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
    when "cancel_job", "retry_job", "rebase_job", "reopen_job", "poll_job_feedback", "check_job_mergeability"
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
    when "fire_scheduled_task_now"
      errors.add(:payload, "scheduled_task_id is required") unless payload["scheduled_task_id"].present?
    when "create_repo_document"
      errors.add(:payload, "repository_id is required") unless payload["repository_id"].present?
      errors.add(:payload, "title is required") if payload["title"].to_s.strip.blank?
      errors.add(:payload, "body is required") if payload["body"].to_s.blank?
    when "delete_repo_document"
      errors.add(:payload, "document_id is required") unless payload["document_id"].present?
    when "delegate_issue"
      errors.add(:payload, "repository_id is required") unless payload["repository_id"].present?
      errors.add(:payload, "issue_number is required") unless payload["issue_number"].present?
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

  def action_job
    chat_session.repository.jobs.find(payload.fetch("job_id"))
  end

  def action_user_job
    user.jobs.find(payload.fetch("job_id"))
  end

  def action_scheduled_task
    ScheduledTask.alive.where(user: user).find(payload.fetch("scheduled_task_id"))
  end

  def action_user_repository
    user.repositories.active.find(payload.fetch("repository_id"))
  end

  def action_user_document
    Document.where(
      attachable_type: "Repository",
      attachable_id: user.repositories.active.select(:id)
    ).find(payload.fetch("document_id"))
  end

  def document_filename(title)
    basename = title.to_s.parameterize.presence || "document"
    "#{basename.first(80)}.md"
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
