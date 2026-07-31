require "mcp"

module Mcp::Tools
  class ListWakeupsTool < MCP::Tool
    PROMPT_PREVIEW_LENGTH = 120

    tool_name "list_wakeups"

    description <<~DESC
      List pending one-shot wakeup turns for this chat session, ordered by fire time.
    DESC

    input_schema(
      properties: {}
    )

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        wakeups = chat_session.wakeups.pending.order(:fire_at, :id)

        Mcp::Tools.success(
          wakeups: wakeups.map { |wakeup| wakeup_payload(wakeup) }
        )
      end

      private

      def wakeup_payload(wakeup)
        {
          id: wakeup.id,
          fire_at: wakeup.fire_at.iso8601,
          delay_remaining_minutes: delay_remaining_minutes(wakeup.fire_at),
          prompt_preview: wakeup.prompt.to_s.each_char.first(PROMPT_PREVIEW_LENGTH).join
        }
      end

      def delay_remaining_minutes(fire_at)
        seconds = fire_at - Time.current
        return 0 if seconds <= 0

        (seconds / 60.0).ceil
      end
    end
  end
end
