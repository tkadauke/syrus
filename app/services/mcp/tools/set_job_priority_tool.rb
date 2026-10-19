require "mcp"

module Mcp::Tools
  class SetJobPriorityTool < MCP::Tool
    extend JobLifecycleToolSupport

    tool_name "set_job_priority"

    description <<~DESC
      Immediately set priority on any existing Job state in this chat session's
      repository (#{Mcp::ControlToolContracts.states(Job.aasm.states.map { |state| state.name.to_s })}).
      This creates no Job, Workflow, WorkUnit, or pending action and queues no
      work. It affects later scheduling/admission decisions; it does not reorder
      or restart work already claimed by a worker and needs no confirmation.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to update." },
        priority: { type: "string", enum: Job::PRIORITIES, description: "New Job priority." }
      },
      required: %w[job_id priority]
    )

    class << self
      def call(job_id:, priority:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = find_repository_job(chat_session, job_id)
        return error if error

        priority = priority.to_s
        return Mcp::Tools.invalid("priority must be one of: #{Job::PRIORITIES.join(', ')}") unless Job::PRIORITIES.include?(priority)

        previous_priority = job.priority
        job.update!(priority: priority)

        Mcp::Tools.success(
          job_id: job.id,
          previous_priority: previous_priority,
          new_priority: job.reload.priority
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
