require "mcp"

module Mcp::Tools
  class AdminListUsersTool < MCP::Tool
    tool_name "admin_list_users"

    description "List all Syrus users with account flags and Job counts."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        return Mcp::Tools.unauthorized("Admin access required") unless admin?(server_context)

        job_counts = Job.group(:user_id).count
        users = User.order(:email_address).map { |user| user_payload(user, job_counts.fetch(user.id, 0)) }
        Mcp::Tools.success(users: users)
      end

      private

      def admin?(server_context)
        server_context.fetch(:chat_session).user.admin?
      end

      def user_payload(user, job_count)
        {
          id: user.id,
          email: user.email_address,
          admin: user.admin?,
          agent_provider: user.agent_provider,
          scheduling_paused: user.scheduling_paused?,
          created_at: user.created_at&.iso8601,
          job_count: job_count
        }
      end
    end
  end
end
