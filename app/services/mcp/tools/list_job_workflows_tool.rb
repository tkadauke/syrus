require "mcp"

module Mcp::Tools
  class ListJobWorkflowsTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "list_job_workflows"

    description "List all Workflows for a Syrus Job visible to this chat session's user, newest first."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id whose Workflows should be listed." }
      },
      required: %w[job_id]
    )

    class << self
      include McpToolPayloads::WorkflowPayload

      def call(job_id:, server_context:)
        job = find_job!(job_id)

        Mcp::Tools.success(job_id: job.id, workflows: workflow_index_for(job))
      end
    end
  end
end
