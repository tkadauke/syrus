require "mcp"

module SyrusChatMcp
  class GetJobDiffTool < MCP::Tool
    tool_name "get_job_diff"

    description "Read the latest stored agent diff for a Job in this chat session's repository."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." }
      },
      required: %w[job_id]
    )

    MAX_DIFF_BYTES = 50.kilobytes

    class << self
      def call(job_id:, server_context:)
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
            message: "No stored diff is available for this Job yet."
          )
        end

        truncated = SyrusChatMcp.truncate_text(diff, MAX_DIFF_BYTES)
        SyrusChatMcp.success(
          job_id: job.id,
          run_id: run.id,
          diff: truncated.fetch(:text),
          truncated: truncated.fetch(:truncated),
          bytes: truncated.fetch(:bytes),
          omitted_bytes: truncated[:omitted_bytes].to_i
        )
      end
    end
  end
end
