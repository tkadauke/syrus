# Pending-action presentation helpers extracted from
# Api::V1::App::ChatsController.
#
# Chat agents can propose side-effecting actions (cancel/retry a job, fire a
# scheduled task, admin operations, ...) that an operator confirms. These
# render the human-readable label, optional detail, and post-confirmation
# notice for such actions. They read only the action record (no per-user
# scoping), so they mix straight back in with no behavior change. Kept private
# on include.
module ChatPendingActions
  private

  def pending_action_label(action)
    payload = action.payload || {}
    case action.action
    when "cancel_job"
      "Cancel #{::App::Presentation.job_slug(payload['job_id'])}"
    when "retry_job"
      "Retry #{::App::Presentation.job_slug(payload['job_id'])}"
    when "force_fail_job"
      "Force fail #{::App::Presentation.job_slug(payload['job_id'])}"
    when "rebase_job"
      "Rebase #{::App::Presentation.job_slug(payload['job_id'])}"
    when "reopen_job"
      "Reopen #{::App::Presentation.job_slug(payload['job_id'])}"
    when "fire_scheduled_task_now"
      "Fire scheduled task ##{payload['scheduled_task_id']}"
    when "create_repo_document"
      "Create document #{payload['title'].to_s.inspect}"
    when "delete_repo_document"
      "Delete document #{payload['title'].to_s.presence || "##{payload['document_id']}"}"
    when "poll_job_feedback"
      "Poll PR feedback for #{::App::Presentation.job_slug(payload['job_id'])}"
    when "check_job_mergeability"
      "Check mergeability for #{::App::Presentation.job_slug(payload['job_id'])}"
    when "delegate_issue"
      "Delegate issue ##{payload['issue_number']}"
    when "pause_landing_queue"
      "Pause landing queue"
    when "resume_landing_queue"
      "Resume landing queue"
    when "submit_chat_feedback"
      "Submit feedback on #{::App::Presentation.job_slug(payload['job_id'])}"
    when "reopen_epic_and_attach_job"
      "Reopen Epic ##{payload['epic_id']} and attach #{::App::Presentation.job_slug(payload['job_id'])}"
    when "admin_kill_process"
      "Kill process ##{payload['process_id']}"
    when "admin_reap_stale_runs"
      "Force-reap stale runs"
    when "admin_pause_polling"
      "Pause repository polling"
    when "admin_unpause_polling"
      "Resume repository polling"
    when "admin_pause_runs"
      "Pause runs"
    when "admin_unpause_runs"
      "Resume runs"
    when "admin_clear_github_cache"
      "Clear GitHub API cache"
    when "admin_pause_user_scheduling"
      "Pause scheduling for user ##{payload['user_id']}"
    when "admin_unpause_user_scheduling"
      "Resume scheduling for user ##{payload['user_id']}"
    when "admin_retry_step"
      "Retry step #{payload['step_slug']} on workflow ##{payload['workflow_id']}"
    when "admin_cleanup_workspace"
      "Delete workspace for workflow ##{payload['workflow_id']}"
    when "admin_refresh_installations"
      "Refresh GitHub App installations"
    else
      payload["label"].presence || action.action_type.to_s.humanize
    end
  end

  def pending_action_detail(action)
    payload = action.payload || {}
    case action.action.presence || action.action_type
    when "submit_chat_feedback"
      payload["feedback"].presence
    when "schedule_recurring"
      [
        [ payload["label"], payload["cron_expression"] ].compact_blank.join(" — ").presence,
        payload["prompt"].presence
      ].compact.join("\n\n").presence
    end
  end

  def pending_action_confirmed_notice(action)
    record = action.result
    case record
    when Workflow
      if record.trigger_kind == "chat_feedback"
        "Feedback submitted. Workflow ##{record.id} has been queued."
      else
        "Pending action confirmed."
      end
    when ScheduledTask
      "Scheduled task created: #{record.name}."
    else
      "Pending action confirmed."
    end
  end
end
