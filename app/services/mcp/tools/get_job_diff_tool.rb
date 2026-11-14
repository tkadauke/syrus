require "mcp"

module Mcp::Tools
  class GetJobDiffTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "get_job_diff"

    description "Read a paginated stored Run diff for a Job, preferring the per-step artifact by default."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        run_id: { type: "integer", description: "Optional Run id. It must belong to the Job." },
        artifact: { type: "string", enum: %w[preferred step_agent_diff agent_diff], description: "Diff artifact. Defaults to preferred (step diff, then cumulative diff)." },
        page: { type: "integer", description: "Diff page number. Defaults to 1." },
        per_bytes: { type: "integer", description: "Maximum diff bytes per page. Defaults to 51200 and is capped at 51200." }
      },
      required: %w[job_id]
    )

    DEFAULT_DIFF_BYTES = 50.kilobytes
    MAX_DIFF_BYTES = 50.kilobytes

    class << self
      def call(job_id:, server_context:, page: 1, per_bytes: DEFAULT_DIFF_BYTES, run_id: nil, artifact: "preferred")
        chat_session = server_context.fetch(:chat_session)
        job = find_job!(job_id)
        context = McpToolContext.from_server_context(server_context)
        if context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])
          access = CoworkerRepositoryAccess.resolve(server_context:, repository_id: job.repository_id)
          return access if access.is_a?(MCP::Tool::Response)
        end

        return Mcp::Tools.invalid("artifact must be preferred, step_agent_diff, or agent_diff") unless artifact.in?(%w[preferred step_agent_diff agent_diff])

        run = selected_run(job, run_id:, artifact:)
        selected_artifact, diff = selected_diff(run, artifact)
        if diff.blank?
          return Mcp::Tools.success(
            job_id: job.id,
            run_id: run&.id,
            artifact_type: selected_artifact,
            diff: nil,
            page: normalize_page(page),
            per_bytes: normalize_per_bytes(per_bytes),
            total_bytes: 0,
            total_pages: 0,
            has_next_page: false,
            message: run_id ? "The requested Run has no #{artifact.tr('_', ' ')} artifact." : "No stored diff is available for this Job yet."
          )
        end

        page = normalize_page(page)
        per_bytes = normalize_per_bytes(per_bytes)
        redacted_diff = ToolPayloadRedactor.redact_text(diff)
        total_bytes = redacted_diff.bytesize
        total_pages = total_pages(total_bytes, per_bytes)
        offset = (page - 1) * per_bytes
        page_out_of_range = offset >= total_bytes
        chunk = page_out_of_range ? "" : Mcp::Tools.safe_byteslice(redacted_diff, offset, per_bytes)
        has_next_page = page < total_pages

        Mcp::Tools.success(
          job_id: job.id,
          run_id: run.id,
          step_kind: run.step&.kind,
          step_iteration: run.step&.iteration,
          artifact_type: selected_artifact,
          byte_count: total_bytes,
          base_sha: run.base_sha,
          head_sha: run.head_sha,
          diff: chunk,
          page: page,
          per_bytes: per_bytes,
          total_bytes: total_bytes,
          total_pages: total_pages,
          has_next_page: has_next_page,
          next_page: (page + 1 if has_next_page),
          page_out_of_range: page_out_of_range,
          message: ("Page #{page} is out of range for this #{total_pages}-page diff." if page_out_of_range)
        )
      end

      private

      def selected_run(job, run_id:, artifact:)
        return job.runs.includes(:step, :run_diff).find(run_id) if run_id.present?

        scope = job.runs.joins(:run_diff).includes(:step, :run_diff)
        scope = case artifact
        when "step_agent_diff"
          scope.where.not(run_diffs: { step_agent_diff: [ nil, "" ] })
        when "agent_diff"
          scope.where.not(run_diffs: { agent_diff: [ nil, "" ] })
        else
          scope.where("NULLIF(run_diffs.step_agent_diff, '') IS NOT NULL OR NULLIF(run_diffs.agent_diff, '') IS NOT NULL")
        end
        scope.reorder(created_at: :desc, id: :desc).first
      end

      def selected_diff(run, artifact)
        return [ artifact == "preferred" ? nil : artifact, nil ] unless run

        case artifact
        when "step_agent_diff" then [ artifact, run.step_agent_diff ]
        when "agent_diff" then [ artifact, run.agent_diff ]
        else
          run.step_agent_diff.present? ? [ "step_agent_diff", run.step_agent_diff ] : [ "agent_diff", run.agent_diff ]
        end
      end

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
