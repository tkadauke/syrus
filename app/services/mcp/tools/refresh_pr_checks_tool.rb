require "mcp"

module Mcp::Tools
  class RefreshPrChecksTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "refresh_pr_checks"
    description "Refresh a Job PR's cached GitHub check-run state and return failing check names and details URLs. Admin/Supervisor only."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        job = find_admin_job(job_id)
        return job if job.is_a?(MCP::Tool::Response)

        Mcp::Tools.success(CiRepair::CheckRefresh.call(job).payload)
      rescue ArgumentError => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def find_admin_job(job_id)
        integer = integer_param(job_id, "job_id")
        return integer if integer.is_a?(MCP::Tool::Response)

        Job.find_by(id: integer) || Mcp::Tools.invalid("job not found: #{integer}")
      end
    end
  end
end
