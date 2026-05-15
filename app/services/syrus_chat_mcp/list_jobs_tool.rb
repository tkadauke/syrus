require "mcp"

module SyrusChatMcp
  class ListJobsTool < MCP::Tool
    tool_name "list_jobs"

    description "List Syrus Jobs for this chat session's repository from Syrus's database."

    input_schema(
      properties: {
        state: { type: "string", enum: %w[open closed], description: "Job state. Defaults to open." },
        label: { type: "string", description: "Optional persisted Syrus label filter." },
        limit: { type: "integer", description: "Maximum Jobs to return. Defaults to 20, capped at 100." }
      }
    )

    class << self
      def call(server_context:, state: "open", label: nil, limit: 20)
        chat_session = server_context.fetch(:chat_session)
        state = state.to_s.presence || "open"
        return SyrusChatMcp.invalid("state must be open or closed") unless %w[open closed].include?(state)

        limit = normalize_limit(limit)
        scope = chat_session.repository.jobs.order(created_at: :desc, id: :desc)
        scope = state == "open" ? scope.open_threads : scope.closed_threads
        scope = apply_label_filter(scope, chat_session.repository, label)
        return scope if scope.is_a?(MCP::Tool::Response)

        SyrusChatMcp.success(
          jobs: scope.limit(limit).map { |job| job_payload(job) }
        )
      end

      private

      def normalize_limit(value)
        value.to_i.clamp(1, 100)
      end

      def apply_label_filter(scope, repository, label)
        label = label.to_s.strip
        return scope if label.empty?
        return scope if label == repository.trigger_label
        return scope.where(skip_prepare: true) if label == Job::PREPARE_SKIP_LABEL

        SyrusChatMcp.invalid("label filtering is only available for #{repository.trigger_label.inspect} and #{Job::PREPARE_SKIP_LABEL.inspect}; arbitrary issue labels are not stored on Jobs")
      end

      def job_payload(job)
        {
          id: job.id,
          kind: job.kind,
          issue_number: job.issue_number,
          pr_number: job.pr_number || job.external_pr_number,
          branch_name: job.branch_name,
          state: job.state,
          closure_reason: job.closure_reason,
          agent_provider: job.agent_provider,
          priority: job.priority,
          issue_title: job.issue_title,
          created_at: job.created_at&.iso8601,
          updated_at: job.updated_at&.iso8601
        }
      end
    end
  end
end
