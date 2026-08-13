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
    ::App::Presentation.pending_action_label(action)
  end

  def pending_action_detail(action)
    ::App::Presentation.pending_action_detail(action)
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
