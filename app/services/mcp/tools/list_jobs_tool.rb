require "mcp"

module Mcp::Tools
  class ListJobsTool < MCP::Tool
    tool_name "list_jobs"

    description "List Syrus Jobs across all the current user's repositories from Syrus's database."

    input_schema(
      properties: {
        state: { type: "string", enum: %w[open closed], description: "Job state. Defaults to open." },
        label: { type: "string", description: "Optional persisted Syrus label filter." },
        limit: { type: "integer", description: "Maximum Jobs to return. Defaults to 20, capped at 100." }
      }
    )

    class << self
      include McpToolPayloads::JobPayload

      def call(server_context:, state: "open", label: nil, limit: 20)
        chat_session = server_context.fetch(:chat_session)
        state = state.to_s.presence || "open"
        return Mcp::Tools.invalid("state must be open or closed") unless %w[open closed].include?(state)

        limit = normalize_limit(limit)
        base_scope = chat_session.user.admin? ? Job.all : chat_session.user.jobs
        scope = base_scope.order(created_at: :desc, id: :desc)
        scope = state == "open" ? scope.open_threads : scope.closed_threads
        scope = apply_label_filter(scope, label)
        return scope if scope.is_a?(MCP::Tool::Response)

        Mcp::Tools.success(
          jobs: scope.limit(limit).map { |job| job_list_payload(job) }
        )
      end

      private

      def normalize_limit(value)
        value.to_i.clamp(1, 100)
      end

      def apply_label_filter(scope, label)
        label = label.to_s.strip
        return scope if label.empty?
        return scope.where(skip_prepare: true) if label == Job::PREPARE_SKIP_LABEL

        Mcp::Tools.invalid("label filtering only supports #{Job::PREPARE_SKIP_LABEL.inspect} across user scope")
      end
    end
  end
end
