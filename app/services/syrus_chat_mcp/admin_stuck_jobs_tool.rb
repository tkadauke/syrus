require "mcp"

module SyrusChatMcp
  class AdminStuckJobsTool < MCP::Tool
    tool_name "admin_stuck_jobs"

    description "Read the admin stuck Jobs list."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        return SyrusChatMcp.unauthorized("Admin access required") unless admin?(server_context)

        items = ::Admin::StuckItems.all.map { |item| stuck_job_payload(item) }
        SyrusChatMcp.success(items: items)
      end

      private

      def admin?(server_context)
        server_context.fetch(:chat_session).user.admin?
      end

      def stuck_job_payload(item)
        run = item.run
        workflow = item.workflow
        job = item.job

        {
          id: job&.id,
          title: job&.issue_title,
          state: job&.state,
          last_heartbeat_at: run&.last_heartbeat_at&.iso8601,
          workflow_state: workflow&.state,
          run_state: run&.state,
          kind: item.kind.to_s,
          severity: item.severity.to_s,
          detail: item.detail,
          workflow_id: workflow&.id,
          run_id: run&.id
        }
      end
    end
  end
end
