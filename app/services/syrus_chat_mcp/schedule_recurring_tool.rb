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
        cron_expression: { type: "string", description: "Five-field cron expression, interpreted in UTC. The minute field is honored; schedules fire at most once per matching hourly window." },
        label: { type: "string", description: "Short operator-facing label for this recurring task." },
        prompt: { type: "string", description: "Prompt to run as a scheduled cron Job each time the schedule fires." }
      },
      required: %w[cron_expression label prompt]
    )

    class << self
      def call(cron_expression:, label:, prompt:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        cron_expression = cron_expression.to_s.strip
        label = label.to_s.strip
        prompt = prompt.to_s.strip

        return SyrusChatMcp.invalid("cron_expression is required") if cron_expression.empty?
        return SyrusChatMcp.invalid("label is required") if label.empty?
        return SyrusChatMcp.invalid("prompt is required") if prompt.empty?

        preview = ScheduledTask.new(
          user: chat_session.user,
          repository: chat_session.repository,
          kind: "cron",
          name: label,
          cron_expression: cron_expression,
          prompt: prompt
        )
        return SyrusChatMcp.invalid(preview.errors.full_messages.to_sentence) unless preview.valid?

        next_fire_at = preview.next_fire_at(from: Time.current)
        action = create_pending_action_message!(
          chat_session,
          user: chat_session.user,
          repository: chat_session.repository,
          action_type: "schedule_recurring",
          payload: {
            "cron_expression" => cron_expression,
            "label" => label,
            "prompt" => prompt,
            "next_fire_at" => next_fire_at&.iso8601
          }
        )

        SyrusChatMcp.success(
          pending_confirmation_id: action.id,
          next_fire_at: next_fire_at&.iso8601
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
