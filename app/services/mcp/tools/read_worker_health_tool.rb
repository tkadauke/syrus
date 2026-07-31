require "mcp"

module Mcp::Tools
  class ReadWorkerHealthTool < MCP::Tool
    tool_name "read_worker_health"

    description "Read live worker host health and compact historical windows, optionally filtered by hostname and ISO8601 time range."

    input_schema(
      properties: {
        hostname: { type: "string", description: "Optional worker hostname to inspect." },
        since: { type: "string", description: "Optional ISO8601 range start. Defaults to 24 hours ago." },
        until: { type: "string", description: "Optional ISO8601 range end. Defaults to now." },
        sample_limit_per_host: { type: "integer", description: "Maximum recent raw samples per hostname, up to 100." },
        minute_bucket_window_minutes: { type: "integer", description: "Minute-resolution history window ending at until, up to 1440 minutes. Defaults to 60." }
      }
    )

    class << self
      def call(server_context:, **arguments)
        return Mcp::Tools.unauthorized("Admin access required") unless admin?(server_context)

        Mcp::Tools.success(
          ::Admin::WorkerHealthPayload.new(
            hostname: arguments[:hostname],
            since: arguments[:since],
            until_time: arguments[:until],
            sample_limit_per_host: arguments.fetch(:sample_limit_per_host, ::Admin::WorkerHealthPayload::SAMPLE_LIMIT_PER_HOST),
            minute_bucket_window_minutes: arguments.fetch(
              :minute_bucket_window_minutes,
              ::Admin::WorkerHealthPayload::DEFAULT_MINUTE_BUCKET_WINDOW / 1.minute
            )
          ).as_json
        )
      end

      private

      def admin?(server_context)
        server_context.fetch(:chat_session).user.admin?
      end
    end
  end
end
