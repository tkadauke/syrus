require "json"

class ChatScopedEventWakeup
  ACTIONABLE_DECISIONS = %w[respond act].freeze

  def initialize(event:, evaluator_result: nil)
    @event = event
    @chat_session = event.chat_session
    @evaluator_result = evaluator_result || event.evaluator_result || {}
  end

  def call
    return unless ACTIONABLE_DECISIONS.include?(@evaluator_result["decision"].to_s)
    return if @event.delivered?

    wakeup = nil
    ChatScopedEvent.transaction(requires_new: true) do
      locked_event = ChatScopedEvent.lock.find(@event.id)
      next if locked_event.delivered?

      wakeup = @chat_session.wakeups.create!(
        user: @chat_session.user,
        prompt: prompt_for(locked_event),
        fire_at: Time.current,
        metadata: metadata_for(locked_event)
      )
      locked_event.mark_delivered!(chat_message: nil)
    end
    wakeup
  end

  private

  def prompt_for(event)
    handoff = @evaluator_result["handoff_prompt"].to_s.presence || default_handoff(event)
    <<~PROMPT.strip
      A scoped Syrus event evaluator decided this event needs a live chat turn.

      Before acting, read current Syrus state for any referenced Job, Workflow, Run, queue, repository, user, or process. The event data below may be stale.

      Evaluator handoff:
      #{handoff}

      Scoped event:
      #{JSON.pretty_generate(event.payload)}

      Evaluator decision:
      #{JSON.pretty_generate(@evaluator_result)}
    PROMPT
  end

  def default_handoff(event)
    "Review the event, verify current state, and provide the appropriate update or proposed action."
  end

  def metadata_for(event)
    {
      "scoped_event_wakeup" => true,
      "scoped_event_id" => event.id,
      "scoped_event" => event.payload.merge("scoped_event_id" => event.id),
      "supervisor_event" => event.payload.merge("scoped_event_id" => event.id),
      "evaluator_decision" => @evaluator_result
    }
  end
end
