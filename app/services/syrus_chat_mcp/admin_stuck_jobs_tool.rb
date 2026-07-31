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
        job = item.job
        ::Admin::StuckItemPayload.serialize(item: item, include_actions: false).merge(
          id: job&.id,
          title: job&.issue_title,
          state: job&.state,
          last_heartbeat_at: item.run&.last_heartbeat_at&.iso8601,
          workflow_state: item.workflow&.state,
          run_state: item.run&.state
        )
      end
    end
  end
end
