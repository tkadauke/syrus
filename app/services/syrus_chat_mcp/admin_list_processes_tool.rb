require "mcp"

module SyrusChatMcp
  class AdminListProcessesTool < MCP::Tool
    STATES = %w[running finished all].freeze
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 100

    tool_name "admin_list_processes"

    description "List SpawnedProcess rows for admin process inspection."

    input_schema(
      properties: {
        state: { type: "string", enum: STATES, description: "Process state filter. Defaults to running." },
        kind: { type: "string", description: "Optional SpawnedProcess kind filter." },
        limit: { type: "integer", description: "Maximum rows to return. Defaults to 20." }
      }
    )

    class << self
      def call(state: "running", kind: nil, limit: DEFAULT_LIMIT, server_context:)
        return SyrusChatMcp.unauthorized("Admin access required") unless admin?(server_context)

        state = state.presence || "running"
        return SyrusChatMcp.invalid("state must be one of #{STATES.join(', ')}") unless STATES.include?(state)
        if kind.present? && !SpawnedProcess::KINDS.include?(kind)
          return SyrusChatMcp.invalid("kind must be one of #{SpawnedProcess::KINDS.join(', ')}")
        end

        scope = SpawnedProcess.order(started_at: :desc)
        scope = scope.running if state == "running"
        scope = scope.finished if state == "finished"
        scope = scope.where(kind: kind) if kind.present?
        processes = scope.limit(normalize_limit(limit)).map { |process| process_payload(process) }

        SyrusChatMcp.success(processes: processes)
      end

      private

      def admin?(server_context)
        server_context.fetch(:chat_session).user.admin?
      end

      def normalize_limit(limit)
        limit.to_i.clamp(1, MAX_LIMIT)
      end

      def process_payload(process)
        metrics = process.host_metrics
        {
          id: process.id,
          kind: process.kind,
          hostname: process.hostname,
          pid: process.pid,
          state: process.running? ? "running" : "finished",
          started_at: process.started_at&.iso8601,
          last_heartbeat_at: process.last_chunk_at&.iso8601,
          cpu: metrics&.dig(:cpu_percent),
          rss: metrics&.dig(:rss_bytes),
          run_id: process.run_id,
          workflow_id: process.workflow_id,
          outcome: process.outcome
        }
      end
    end
  end
end
