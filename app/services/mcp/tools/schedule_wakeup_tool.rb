require "mcp"

module Mcp::Tools
  class ScheduleWakeupTool < MCP::Tool
    MIN_DELAY_MINUTES = 1
    MAX_DELAY_MINUTES = 1440

    tool_name "schedule_wakeup"

    description <<~DESC
      Schedule a one-shot wakeup turn in this chat session. At the given time,
      Syrus will start a new agent turn with `prompt` as the input.
      Write the prompt to be fully self-contained -- include which job to check,
      what action to take, and what to do if the condition is not yet met.
    DESC

    input_schema(
      properties: {
        prompt: { type: "string", description: "Fully self-contained prompt for the future wakeup turn." },
        delay_minutes: { type: "integer", description: "Minutes from now to fire (minimum 1, maximum 1440)." }
      },
      required: %w[prompt delay_minutes]
    )

    class << self
      def call(prompt:, delay_minutes:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        prompt = prompt.to_s.strip
        delay_minutes = Integer(delay_minutes, exception: false)

        return Mcp::Tools.invalid("prompt is required") if prompt.blank?
        unless delay_minutes && delay_minutes.between?(MIN_DELAY_MINUTES, MAX_DELAY_MINUTES)
          return Mcp::Tools.invalid("delay_minutes must be between #{MIN_DELAY_MINUTES} and #{MAX_DELAY_MINUTES}")
        end

        fire_at = delay_minutes.minutes.from_now
        wakeup = ChatWakeup.create!(
          chat_session: chat_session,
          user: chat_session.user,
          prompt: prompt,
          fire_at: fire_at
        )

        Mcp::Tools.success(
          wakeup_id: wakeup.id,
          fire_at: wakeup.fire_at.iso8601,
          message: "Wakeup scheduled for #{wakeup.fire_at.iso8601}"
        )
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
