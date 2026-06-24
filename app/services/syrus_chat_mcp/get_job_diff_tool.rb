require "mcp"

module SyrusChatMcp
  class GetJobDiffTool < MCP::Tool
    tool_name "get_job_diff"

    description "Read the latest stored agent diff for a Job in this chat session's repository."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        page: { type: "integer", description: "Diff page number. Defaults to 1." },
        per_bytes: { type: "integer", description: "Maximum diff bytes per page. Defaults to 51200 and is capped at 51200." }
      },
      required: %w[job_id]
    )

    DEFAULT_DIFF_BYTES = 50.kilobytes
    MAX_DIFF_BYTES = 50.kilobytes

    class << self
      def call(job_id:, server_context:, page: 1, per_bytes: DEFAULT_DIFF_BYTES)
        chat_session = server_context.fetch(:chat_session)
        repository = chat_session.repository
        return SyrusChatMcp.invalid("this chat session has no repository attached") unless repository

        job = repository.jobs.find_by(id: job_id)
        return SyrusChatMcp.invalid("job not found in this repository: #{job_id}") unless job

        run = job.latest_workflow&.runs&.order(created_at: :desc, id: :desc)&.first
        diff = run&.agent_diff.to_s
        if diff.blank?
          return SyrusChatMcp.success(
            job_id: job.id,
            run_id: run&.id,
            diff: nil,
            page: normalize_page(page),
            per_bytes: normalize_per_bytes(per_bytes),
            total_bytes: 0,
            total_pages: 0,
            has_next_page: false,
            message: "No stored diff is available for this Job yet."
          )
        end

        page = normalize_page(page)
        per_bytes = normalize_per_bytes(per_bytes)
        total_bytes = diff.bytesize
        total_pages = total_pages(total_bytes, per_bytes)
        offset = (page - 1) * per_bytes
        chunk = offset >= total_bytes ? "" : SyrusChatMcp.safe_byteslice(diff, offset, per_bytes)
        has_next_page = page < total_pages

        SyrusChatMcp.success(
          job_id: job.id,
          run_id: run.id,
          diff: chunk,
          page: page,
          per_bytes: per_bytes,
          total_bytes: total_bytes,
          total_pages: total_pages,
          has_next_page: has_next_page,
          next_page: (page + 1 if has_next_page)
        )
      end

      private

      def normalize_page(value)
        [ value.to_i, 1 ].max
      end

      def normalize_per_bytes(value)
        value.to_i.clamp(1, MAX_DIFF_BYTES)
      end

      def total_pages(total_bytes, per_bytes)
        return 0 if total_bytes.zero?

        (total_bytes.to_f / per_bytes).ceil
      end
    end
  end
end
