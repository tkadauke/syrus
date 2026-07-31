require "mcp"

module Mcp::Tools
  class UpdateScheduledTaskTool < MCP::Tool
    extend ScheduledTaskToolSupport

    tool_name "update_scheduled_task"

    description <<~DESC
      Update fields on a scheduled task. All fields except scheduled_task_id are optional —
      only supplied fields are changed. Pass schedule_input only for cron tasks and fire_at
      only for one_shot tasks; supplying the wrong field for the task kind returns an error.
    DESC

    input_schema(
      properties: {
        scheduled_task_id: {
          type: "integer",
          description: "ScheduledTask id to update."
        },
        name: {
          type: "string",
          description: "New operator-facing label for the task."
        },
        prompt: {
          type: "string",
          description: "New prompt text for the task."
        },
        schedule_input: {
          type: "string",
          description: "Natural cadence text or a five-field cron expression (cron tasks only)."
        },
        cron_expression: {
          type: "string",
          description: "Compatibility alias for schedule_input when providing a five-field cron expression."
        },
        fire_at: {
          type: "string",
          description: "New ISO 8601 datetime for when to fire (one_shot tasks only)."
        },
        pr_pileup_policy: {
          type: "string",
          enum: ScheduledTask::PR_PILEUP_POLICIES,
          description: "New pileup policy: skip, pile, or replace."
        }
      },
      required: %w[scheduled_task_id]
    )

    class << self
      def call(scheduled_task_id:, server_context:, name: nil, prompt: nil,
               schedule_input: nil, cron_expression: nil, fire_at: nil, pr_pileup_policy: nil)
        chat_session = server_context.fetch(:chat_session)
        task, error = find_scheduled_task(chat_session, scheduled_task_id)
        return error if error

        if (schedule_input || cron_expression) && task.one_shot?
          return Mcp::Tools.invalid("schedule_input cannot be set on a one_shot task")
        end

        if fire_at && task.cron?
          return Mcp::Tools.invalid("fire_at cannot be set on a cron task")
        end

        attrs = {}
        attrs[:name] = name if name
        attrs[:prompt] = prompt if prompt
        attrs[:schedule_input] = schedule_input || cron_expression if schedule_input || cron_expression
        attrs[:cron_expression] = cron_expression if cron_expression
        attrs[:fire_at] = Time.parse(fire_at) if fire_at
        attrs[:pr_pileup_policy] = pr_pileup_policy if pr_pileup_policy

        return Mcp::Tools.invalid("no fields provided to update") if attrs.empty?

        task.update!(attrs)

        Mcp::Tools.success(scheduled_task: scheduled_task_payload(task).merge(prompt: task.prompt))
      rescue ArgumentError => e
        Mcp::Tools.invalid("invalid fire_at: #{e.message}")
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
