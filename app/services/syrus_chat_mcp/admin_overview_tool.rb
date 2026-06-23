require "mcp"

module SyrusChatMcp
  class AdminOverviewTool < MCP::Tool
    tool_name "admin_overview"

    description "Read the admin overview rollup for users, repositories, jobs, workflows, and queue health."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        return SyrusChatMcp.unauthorized("Admin access required") unless admin?(server_context)

        overview = ::Admin::OverviewPayload.new.as_json
        SyrusChatMcp.success(
          total_users: User.count,
          active_repositories: Repository.active.count,
          open_jobs: Job.open_threads.count,
          running_workflows: Workflow.where(state: "running").count,
          queue_summary: {
            active: overview.dig(:active_runs, :total),
            pending: overview.dig(:queued_runs, :total),
            failed: overview.dig(:recent_failures_24h, :total)
          },
          overview: overview
        )
      end

      private

      def admin?(server_context)
        server_context.fetch(:chat_session).user.admin?
      end
    end
  end
end
