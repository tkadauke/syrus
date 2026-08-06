require "mcp"

module SyrusChatMcp
  class ScheduleRecurringTool < MCP::Tool
    extend ProposalToolSupport

    tool_name "schedule_recurring"

    description <<~DESC
      Request creation of a recurring task for this repository. The task is
      not created immediately; Syrus returns a pending_confirmation_id and
      waits for the operator to confirm the pending action.
    DESC

    input_schema(
      properties: {
        schedule_input: { type: "string", description: "Natural cadence text such as 'Every Monday at 9:00 AM' or a five-field cron expression. Interpreted in UTC." },
        cron_expression: { type: "string", description: "Compatibility alias for schedule_input when providing a five-field cron expression." },
        label: { type: "string", description: "Short operator-facing label for this recurring task." },
        prompt: { type: "string", description: "Prompt to run as a scheduled cron Job each time the schedule fires." }
      },
      required: %w[label prompt]
    )

    class << self
      def call(label:, prompt:, server_context:, schedule_input: nil, cron_expression: nil)
        chat_session = server_context.fetch(:chat_session)
        schedule_input = schedule_input.to_s.strip.presence || cron_expression.to_s.strip
        label = label.to_s.strip
        prompt = prompt.to_s.strip

        return SyrusChatMcp.invalid("schedule_input is required") if schedule_input.empty?
        return SyrusChatMcp.invalid("label is required") if label.empty?
        return SyrusChatMcp.invalid("prompt is required") if prompt.empty?

        preview = ScheduledTask.new(
          user: chat_session.user,
          repository: chat_session.repository,
          kind: "cron",
          name: label,
          schedule_input: schedule_input,
          cron_expression: cron_expression,
          prompt: prompt
        )
        return SyrusChatMcp.invalid(preview.errors.full_messages.to_sentence) unless preview.valid?

        next_fire_at = preview.next_fire_at(from: Time.current)
        action = create_pending_action_for_current_message!(
          server_context,
          chat_session,
          user: chat_session.user,
          repository: chat_session.repository,
          action_type: "schedule_recurring",
          payload: {
            "schedule_input" => schedule_input,
            "cron_expression" => preview.cron_expression,
            "schedule_expression" => preview.schedule_expression,
            "schedule_explanation" => preview.schedule_explanation,
            "schedule_timezone" => preview.schedule_timezone,
            "label" => label,
            "prompt" => prompt,
            "next_fire_at" => next_fire_at&.iso8601
          }
        )

        SyrusChatMcp.success(
          pending_confirmation_id: action.id,
          schedule_explanation: preview.schedule_explanation,
          next_fire_at: next_fire_at&.iso8601
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
