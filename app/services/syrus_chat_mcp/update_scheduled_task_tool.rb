require "mcp"

module SyrusChatMcp
  class UpdateScheduledTaskTool < MCP::Tool
    extend ScheduledTaskToolSupport

    tool_name "update_scheduled_task"

    description <<~DESC
      Update fields on a scheduled task. All fields except scheduled_task_id are optional —
      only supplied fields are changed. Pass cron_expression only for cron tasks and fire_at
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
        cron_expression: {
          type: "string",
          description: "New cron expression (cron tasks only). Must fire at most once per hour."
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
               cron_expression: nil, fire_at: nil, pr_pileup_policy: nil)
        chat_session = server_context.fetch(:chat_session)
        task, error = find_scheduled_task(chat_session, scheduled_task_id)
        return error if error

        if cron_expression && task.one_shot?
          return SyrusChatMcp.invalid("cron_expression cannot be set on a one_shot task")
        end

        if fire_at && task.cron?
          return SyrusChatMcp.invalid("fire_at cannot be set on a cron task")
        end

        attrs = {}
        attrs[:name] = name if name
        attrs[:prompt] = prompt if prompt
        attrs[:cron_expression] = cron_expression if cron_expression
        attrs[:fire_at] = Time.parse(fire_at) if fire_at
        attrs[:pr_pileup_policy] = pr_pileup_policy if pr_pileup_policy

        return SyrusChatMcp.invalid("no fields provided to update") if attrs.empty?

        task.update!(attrs)

        SyrusChatMcp.success(scheduled_task: scheduled_task_payload(task).merge(prompt: task.prompt))
      rescue ArgumentError => e
        SyrusChatMcp.invalid("invalid fire_at: #{e.message}")
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
