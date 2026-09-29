require "mcp"

module Mcp::Tools
  class ScheduleWakeupTool < MCP::Tool
    MIN_DELAY_MINUTES = 1
    MAX_DELAY_MINUTES = 1440
    MAX_FIRE_AT = 1.year

    tool_name "schedule_wakeup"

    description <<~DESC
      Schedule a one-shot wakeup turn in this chat session. At the given time,
      Syrus will start a new agent turn with `prompt` as the input.
      Use `delay_minutes` only for short relative reminders within 24 hours.
      Use `fire_at` as an absolute UTC ISO 8601 timestamp for specific dates,
      times, or longer one-shot reminders instead of scheduling relay wakeups.
      Write the prompt to be fully self-contained -- include which job to check,
      what action to take, and what to do if the condition is not yet met.
    DESC

    input_schema(
      properties: {
        prompt: { type: "string", description: "Fully self-contained prompt for the future wakeup turn." },
        delay_minutes: { type: "integer", description: "Minutes from now to fire (minimum 1, maximum 1440). Use only for short relative reminders." },
        fire_at: { type: "string", description: "Absolute UTC ISO 8601 timestamp to fire at, such as 2026-10-13T09:00:00Z. Use for specific dates/times or reminders more than 24 hours out." }
      },
      required: %w[prompt]
    )

    class << self
      def call(prompt:, server_context:, delay_minutes: nil, fire_at: nil)
        chat_session = server_context.fetch(:chat_session)
        prompt = prompt.to_s.strip

        return Mcp::Tools.invalid("prompt is required") if prompt.blank?

        fire_at = resolve_fire_at(delay_minutes: delay_minutes, fire_at: fire_at)
        return fire_at if fire_at.is_a?(MCP::Tool::Response)

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

      private

      def resolve_fire_at(delay_minutes:, fire_at:)
        delay_provided = delay_minutes.present?
        fire_at_provided = fire_at.present?

        if delay_provided == fire_at_provided
          return Mcp::Tools.invalid("provide exactly one of delay_minutes or fire_at")
        end

        return resolve_delay_minutes(delay_minutes) if delay_provided

        resolve_absolute_fire_at(fire_at)
      end

      def resolve_delay_minutes(delay_minutes)
        delay_minutes = Integer(delay_minutes, exception: false)
        unless delay_minutes && delay_minutes.between?(MIN_DELAY_MINUTES, MAX_DELAY_MINUTES)
          return Mcp::Tools.invalid("delay_minutes must be between #{MIN_DELAY_MINUTES} and #{MAX_DELAY_MINUTES}")
        end

        delay_minutes.minutes.from_now
      end

      def resolve_absolute_fire_at(fire_at)
        parsed = Time.iso8601(fire_at.to_s).in_time_zone
        return Mcp::Tools.invalid("fire_at must be in the future") unless parsed.future?
        if parsed > MAX_FIRE_AT.from_now
          return Mcp::Tools.invalid("fire_at must be within #{MAX_FIRE_AT.inspect} from now")
        end

        parsed
      rescue ArgumentError
        Mcp::Tools.invalid("fire_at must be an ISO 8601 timestamp")
      end
    end
  end
end
