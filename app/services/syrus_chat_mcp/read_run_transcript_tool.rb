require "mcp"

module SyrusChatMcp
  class ReadRunTranscriptTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "read_run_transcript"

    description "Read paginated transcript chunks and full agent diff for a Run visible to this chat session's user."

    input_schema(
      properties: {
        run_id: { type: "integer", description: "Syrus Run id to inspect." },
        page: { type: "integer", description: "Transcript page number. Defaults to 1." },
        per: { type: "integer", description: "Chunks per page. Defaults to 50, capped at 200." }
      },
      required: %w[run_id]
    )

    class << self
      def call(run_id:, server_context:, page: 1, per: 50)
        run = find_run!(run_id)

        page = normalize_page(page)
        per = normalize_per(per)
        logs = run.job_logs.order(:sequence)
        total_chunks = logs.count

        SyrusChatMcp.success(
          run_id: run.id,
          run_state: run.state,
          agent_outcome: run.agent_outcome,
          agent_summary: run.agent_summary,
          agent_diff: run.agent_diff,
          total_chunks: total_chunks,
          page: page,
          per: per,
          total_pages: total_pages(total_chunks, per),
          chunks: logs.offset((page - 1) * per).limit(per).map { |log| log_payload(log) }
        )
      end

      private

      def normalize_page(value)
        [ value.to_i, 1 ].max
      end

      def normalize_per(value)
        value.to_i.clamp(1, 200)
      end

      def total_pages(total_chunks, per)
        return 0 if total_chunks.zero?

        (total_chunks.to_f / per).ceil
      end

      def log_payload(log)
        {
          sequence: log.sequence,
          kind: log.kind,
          chunk: log.chunk
        }
      end
    end
  end
end
