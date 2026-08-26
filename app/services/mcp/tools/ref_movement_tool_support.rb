module Mcp::Tools
  # Shared lookups for the Story 11 (docs/plans/delivery-tracks-and-promotion.md)
  # delivery-track/ref-movement MCP tools. Works from either surface
  # (`McpToolContext#chat?`/`#run?`) the same way `WriteMemoryTool` does,
  # since these tools are both chat- and skill-facing.
  module RefMovementToolSupport
    private

    def find_context_job(context, job_id)
      normalized_id = Integer(job_id, exception: false)
      return [ nil, Mcp::Tools.invalid("job_id must be an integer") ] unless normalized_id

      scope = context.user.admin? ? Job.all : context.user.jobs
      job = scope.find_by(id: normalized_id)
      return [ nil, Mcp::Tools.invalid("job not found: #{normalized_id}") ] unless job

      [ job, nil ]
    end

    def find_context_ref_movement_action(context, id)
      normalized_id = Integer(id, exception: false)
      return [ nil, Mcp::Tools.invalid("ref_movement_action_id must be an integer") ] unless normalized_id

      scope = context.user.admin? ? RefMovementAction.all : RefMovementAction.where(repository: context.user.repositories)
      action = scope.find_by(id: normalized_id)
      return [ nil, Mcp::Tools.invalid("ref_movement_action not found: #{normalized_id}") ] unless action

      [ action, nil ]
    end

    def invalid_record(error)
      Mcp::Tools.invalid(error.record.errors.full_messages.to_sentence)
    end
  end
end
