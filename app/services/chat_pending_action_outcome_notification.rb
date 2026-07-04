class ChatPendingActionOutcomeNotification
  SOURCE = "pending_action_notification".freeze

  def initialize(pending_action)
    @pending_action = pending_action
  end

  def acknowledgment(outcome:)
    kind = pending_action.action.presence || pending_action.action_type
    detail = action_detail

    case outcome.to_sym
    when :confirmed
      "Pending action confirmed: #{kind} (#{detail}). The action has been applied."
    when :rejected
      "Pending action rejected: #{kind} (#{detail}). The action was not applied."
    when :cancelled
      "Pending action dismissed: #{kind} (#{detail}). The action was not applied."
    else
      raise ArgumentError, "unknown pending action outcome: #{outcome}"
    end
  end

  private

  attr_reader :pending_action

  def action_detail
    payload = pending_action.payload.to_h
    kind = pending_action.action.presence || pending_action.action_type

    case kind
    when "cancel_job", "retry_job", "rebase_job", "reopen_job",
         "poll_job_feedback", "check_job_mergeability", "submit_chat_feedback"
      "job_id: #{payload["job_id"]}"
    when "reopen_epic_and_attach_job"
      "epic_id: #{payload["epic_id"]}, job_id: #{payload["job_id"]}"
    when "fire_scheduled_task_now"
      "scheduled_task_id: #{payload["scheduled_task_id"]}"
    when "create_repo_document"
      "title: #{payload["title"]}"
    when "delete_repo_document"
      "document_id: #{payload["document_id"]}"
    when "delegate_issue"
      "issue_number: #{payload["issue_number"]}"
    when "admin_kill_process"
      "process_id: #{payload["process_id"]}"
    when "admin_pause_user_scheduling", "admin_unpause_user_scheduling"
      "user_id: #{payload["user_id"]}"
    when "admin_retry_step"
      "workflow_id: #{payload["workflow_id"]}, step_slug: #{payload["step_slug"]}"
    when "admin_cleanup_workspace"
      "workflow_id: #{payload["workflow_id"]}"
    when "schedule_recurring"
      "label: #{payload["label"]}"
    else
      "id: #{pending_action.id}"
    end
  end
end
