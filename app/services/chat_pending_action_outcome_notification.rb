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
    kind = pending_action.action.presence || pending_action.action_type
    PendingActions.for(kind).new(pending_action).action_detail
  rescue PendingActions::UnknownAction
    "id: #{pending_action.id}"
  end
end
