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
    return "Pending action queued." if action.confirming?

    record = action.result

    # The action names its own result. Core used to `case` over the models a
    # confirmation could produce, which meant naming a plugin's model here.
    supplied = handler_confirmed_notice(action, record)
    return supplied if supplied.present?

    case record
    when Workflow
      if record.trigger_kind == "chat_feedback"
        "Feedback submitted. Workflow ##{record.id} has been queued."
      else
        "Pending action confirmed."
      end
    else
      "Pending action confirmed."
    end
  end

  def handler_confirmed_notice(action, record)
    handler = PendingActions.for(action.action_key)
    return nil unless handler.respond_to?(:confirmed_notice)

    handler.confirmed_notice(record)
  rescue StandardError => e
    Rails.logger.warn("[ChatPendingActions] confirmation notice failed for #{action.action_key}: #{e.class}: #{e.message}")
    nil
  end

  def pending_action_group_confirmed_notice(group)
    members = group.chat_pending_actions.reload.to_a
    failed = members.count(&:failed?)
    succeeded = members.count(&:confirmed?)
    return "Confirmed #{succeeded} #{'pending action'.pluralize(succeeded)}." if failed.zero?

    "Confirmed #{succeeded} of #{members.size} pending actions; #{failed} failed."
  end

  def pending_action_group_rejected_notice(group)
    "Rejected #{group.chat_pending_actions.count} pending actions."
  end
end
