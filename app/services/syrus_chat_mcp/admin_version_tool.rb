require "mcp"

module SyrusChatMcp
  class AdminVersionTool < MCP::Tool
    tool_name "admin_version"

    description "Read the running Syrus git SHA and live instance versions."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        return SyrusChatMcp.unauthorized("Admin access required") unless admin?(server_context)

        SyrusChatMcp.success(
          request_handler: {
            hostname: SyrusVersion.hostname,
            role: SyrusVersion.role,
            version: SyrusVersion.current
          },
          instances: InstanceVersion.fresh.order(:role, :hostname).map { |instance| instance_payload(instance) }
        )
      end

      private

      def admin?(server_context)
        server_context.fetch(:chat_session).user.admin?
      end

      def instance_payload(instance)
        {
          id: instance.id,
          hostname: instance.hostname,
          role: instance.role,
          version: instance.version,
          started_at: instance.started_at&.iso8601,
          last_heartbeat_at: instance.last_heartbeat_at&.iso8601
        }
      end
    end
  end
end
