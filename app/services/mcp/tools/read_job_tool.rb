require "mcp"

module Mcp::Tools
  class ReadJobTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "read_job"

    description <<~DESC
      Read Syrus Job metadata, the latest Workflow summary, and the latest
      Workflow transcript head/tail for a Job in this chat session's repository.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to inspect." }
      },
      required: %w[job_id]
    )

    class << self
      include McpToolPayloads::JobPayload
      include McpToolPayloads::WorkflowPayload

      def call(job_id:, server_context:)
        job = find_job!(
          job_id,
          includes: [
            :repository,
            :deployment_stage_statuses,
            :canonical_job,
            { dependencies: [ { depends_on_job: :repository }, :depends_on_epic ] },
            { workflows: { steps: :runs } }
          ]
        )

        workflow = job.latest_workflow
        workflows_index = job.workflows
                             .includes(steps: :runs)
                             .reorder(created_at: :desc, id: :desc)
                             .map { |wf| workflow_index_payload(wf) }
        Mcp::Tools.success(
          job: job_detail_payload(job, include_state_transitions: true),
          workflow_count: workflows_index.size,
          workflows_index: workflows_index,
          latest_workflow: workflow_summary_payload(workflow),
          transcript: transcript_payload(workflow)
        )
      end

      private

      def transcript_payload(workflow)
        return nil unless workflow

        run_ids = workflow.steps.flat_map { |step| step.runs.map(&:id) }.compact
        return Mcp::Tools.head_tail("") if run_ids.empty?

        logs = JobLog.where(run_id: run_ids).order(:sequence, :id)
        total_chunks = logs.count
        sample_chunks = logs.limit(20).pluck(:chunk)
        tail_chunks = total_chunks > 20 ? logs.offset([ total_chunks - 20, 0 ].max).limit(20).pluck(:chunk) : []
        text = (sample_chunks + tail_chunks).join
        payload = Mcp::Tools.head_tail(text)
        payload[:total_chunks] = total_chunks
        payload[:sampled_chunks] = sample_chunks.size + tail_chunks.size
        payload[:truncated] = total_chunks > payload[:sampled_chunks]
        payload[:read_run_transcript_hint] = "Use read_run_transcript(run_id, page, per) for full paginated logs."
        payload
      end
    end
  end
end
