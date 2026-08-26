require "mcp"

module Mcp::Tools
  class ListRefMovementActionsTool < MCP::Tool
    extend RefMovementToolSupport

    tool_name "list_ref_movement_actions"

    description "List this repository's configured delivery.ref_movement_actions, whether each is " \
                "currently available to dispatch, and why an unavailable one is blocked. Pass job_id " \
                "to check availability for a job-scoped action like send_job_upstream."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Optional Syrus Job id — required to evaluate availability of job-scoped actions like send_job_upstream." }
      }
    )

    class << self
      def call(server_context:, job_id: nil)
        context = McpToolContext.from_server_context(server_context)
        repository = context.repository
        return Mcp::Tools.invalid("no repository attached") unless repository

        job = nil
        if job_id.present?
          job, error = find_context_job(context, job_id)
          return error if error
          return Mcp::Tools.invalid("job belongs to a different repository") unless job.repository_id == repository.id
        end

        policy = DeliveryPolicy.for(repository: repository)

        actions = policy.ref_movement_actions.map do |name, config|
          available, reason = RefMovementActions::Base.for(name).available?(repository: repository, job: job)
          {
            name: name,
            enabled: config.enabled,
            mode: config.mode,
            grade_phases: config.grade_phases,
            available: config.enabled && available,
            blocked_reason: config.enabled ? (available ? nil : reason) : "not enabled in delivery.ref_movement_actions"
          }
        end

        Mcp::Tools.success(repository: repository.slug, job_id: job&.id, ref_movement_actions: actions)
      end
    end
  end
end
