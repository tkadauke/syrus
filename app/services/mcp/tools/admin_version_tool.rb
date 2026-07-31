require "mcp"

module Mcp::Tools
  class AdminVersionTool < MCP::Tool
    tool_name "admin_version"

    description "Read the running Syrus git SHA and live instance versions."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        return Mcp::Tools.unauthorized("Admin access required") unless admin?(server_context)

        Mcp::Tools.success(
          request_handler: {
            hostname: SyrusVersion.hostname,
            role: SyrusVersion.role,
            version: SyrusVersion.current
          },
          instances: InstanceVersion.fresh.order(:role, :hostname).map { |instance| instance_payload(instance) },
          worker_health: ::Admin::WorkerHealthPayload.new(sample_limit_per_host: 4).as_json
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
          last_heartbeat_at: instance.last_heartbeat_at&.iso8601,
          data_root_usage: instance.data_root_usage_json
        }
      end
    end
  end
end
