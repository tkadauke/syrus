class ChatPendingActionOutcomeNotification
  SOURCE = "pending_action_notification".freeze

  def initialize(pending_action)
    @pending_action = pending_action
  end

  def acknowledgment(outcome:)
    kind = pending_action.action.presence || pending_action.action_type
    detail = [ ("pending_action_id: #{pending_action.id}" if pending_action.id), action_detail, reason_detail ].compact.join(", ")

    case outcome.to_sym
    when :confirmed
      if kind == "coworker_tool_call"
        result = pending_action.payload.to_h["tool_result"].to_s
        return "Coworker tool approved and executed: #{detail}. Result: #{result}"
      end
      return "Pending action confirmed: #{kind} (#{detail}). #{no_op_message}" if no_op? || pending_action.execution_status == "noop"

      if pending_action.execution_status == "partial"
        return "Pending action confirmed: #{kind} (#{detail}). The action was partially applied. #{pending_action.execution_step}".strip
      end

      [
        "Pending action confirmed: #{kind} (#{detail}). The action has been applied.",
        result_notice,
        github_result_notice
      ].compact.join(" ")
    when :rejected
      "Pending action rejected: #{kind} (#{detail}). The action was not applied."
    when :cancelled
      "Pending action cancelled: #{kind} (#{detail}). The action was not applied."
    when :failed
      application = pending_action.execution_status == "rejected" ? "The action was rejected during revalidation and was not applied." : "The action failed before application."
      error = pending_action.execution_error.presence || "No execution error was recorded."
      "Pending action failed: #{kind} (#{detail}, execution_status: #{pending_action.execution_status || 'failed'}). #{application} Error: #{error}"
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

  def reason_detail
    return if pending_action.reason.blank?

    "reason: #{pending_action.reason}"
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

  def result_notice
    result = pending_action.result
    return unless result

    state = result.respond_to?(:state) ? result.state : nil
    [ "Result: #{result.class.name} ##{result.id}", ("state: #{state}" if state.present?) ].compact.join(", ") + "."
  end

  def no_op?
    pending_action.payload.to_h["no_op"] == true
  end

  def no_op_message
    pending_action.payload.to_h["no_op_message"].presence || "No changes were needed."
  end

  def github_failure_summary(result)
    [
      result.dig("comment", "error"),
      result.dig("close", "error")
    ].compact.join("; ").presence || "unknown GitHub error"
  end
end
