require "mcp"

module SyrusMcp
  class ReadInsightRunTranscriptTool < MCP::Tool
    tool_name "read_run_transcript"

    description <<~DESC
      Read paginated JobLog transcript chunks for a Run in the current insight
      run's repository. Returned transcript text and agent summaries/diffs are
      redacted for secret-shaped values.
    DESC

    input_schema(
      properties: {
        run_id: {
          type: "integer",
          description: "Syrus Run id to inspect. Must belong to the current repository."
        },
        page: {
          type: "integer",
          description: "Transcript page number. Defaults to 1."
        },
        per: {
          type: "integer",
          description: "Chunks per page. Defaults to 50, capped at 200."
        }
      },
      required: %w[run_id]
    )

    class << self
      include McpToolPayloads::WorkflowPayload

      DEFAULT_PER = 50
      MAX_PER = 200

      def call(run_id:, server_context:, page: nil, per: nil)
        context_run = SyrusMcp.run_from_context(server_context)
        target_run = Run
          .joins(step: { workflow: :job })
          .includes(:job, :step)
          .where(jobs: { repository_id: context_run.job.repository_id, user_id: context_run.job.user_id })
          .find_by(id: run_id)

        return SyrusMcp.invalid("run_id is outside this repository scope") unless target_run

        page_num = normalized_page(page)
        per_page = normalized_per(per)
        logs = target_run.job_logs.order(:sequence)
        total_chunks = logs.count

        MCP::Tool::Response.new([
          {
            type: "text",
            text: JSON.generate(
              run_id: target_run.id,
              job_id: target_run.job_id,
              workflow_id: target_run.workflow&.id,
              step_kind: target_run.step&.kind,
              run_state: target_run.state,
              agent_outcome: target_run.agent_outcome,
              agent_summary: redact(target_run.agent_summary),
              agent_diff: redact(target_run.agent_diff),
              total_chunks: total_chunks,
              page: page_num,
              per: per_page,
              total_pages: total_pages(total_chunks, per_page),
              chunks: logs.offset((page_num - 1) * per_page).limit(per_page).map { |log| redacted_log_payload(log) }
            )
          }
        ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::ReadInsightRunTranscriptTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def normalized_page(value)
        [ Integer(value.presence || 1, exception: false) || 1, 1 ].max
      end

      def normalized_per(value)
        n = Integer(value.presence || DEFAULT_PER, exception: false)
        n ? n.clamp(1, MAX_PER) : DEFAULT_PER
      end

      def total_pages(total_chunks, per)
        return 0 if total_chunks.zero?

        (total_chunks.to_f / per).ceil
      end

      def redacted_log_payload(log)
        run_log_payload(log).merge(chunk: redact(log.chunk))
      end

      def redact(value)
        SyrusMcp::EvidenceRedactor.call(value)
      end
    end
  end
end
