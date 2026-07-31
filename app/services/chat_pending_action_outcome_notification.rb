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
      [
        "Pending action confirmed: #{kind} (#{detail}). The action has been applied.",
        github_result_notice
      ].compact.join(" ")
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
    kind = pending_action.action.presence || pending_action.action_type
    PendingActions.for(kind).new(pending_action).action_detail
  rescue PendingActions::UnknownAction
    "id: #{pending_action.id}"
  end

  def github_result_notice
    return unless (pending_action.action.presence || pending_action.action_type) == "close_job_successfully"

    result = pending_action.payload.to_h["github_result"].to_h
    case result["status"]
    when "closed"
      "PR ##{result['pr_number']} was commented on if requested and closed."
    when "partial_failure"
      "Job state was closed successfully, but PR cleanup was partial: #{github_failure_summary(result)}."
    when "skipped"
      "Job state was closed successfully, but PR cleanup was skipped: #{result['message']}"
    when "not_applicable"
      "No tracked PR needed cleanup."
    end
  end

  def github_failure_summary(result)
    [
      result.dig("comment", "error"),
      result.dig("close", "error")
    ].compact.join("; ").presence || "unknown GitHub error"
  end
end
