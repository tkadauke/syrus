require "mcp"

module Mcp::Tools
  class ReadJobTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "read_job"

    description <<~DESC
      Read Syrus Job metadata, the latest Workflow summary, and the latest
      Workflow transcript head/tail for a Job in this chat session's repository.
      Includes the bounded canonical recovery decision and intervention history.
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
            { dependencies: [ { depends_on_job: :repository }, :depends_on_epic ] }
          ]
        )

        workflow = job.latest_workflow
        workflows_index = workflow_index_for(job)
        Mcp::Tools.success(
          job: job_detail_payload(job, include_state_transitions: true),
          workflow_count: workflows_index.size,
          workflows_index: workflows_index,
          latest_workflow: workflow_summary_payload(workflow),
          recovery: RecoveryContract.for_job(job),
          transcript: transcript_payload(workflow)
        )
      rescue ActiveRecord::StatementInvalid => error
        Mcp::Tools.database_error(error, operation: "Job inspection")
      end

      private

      def transcript_payload(workflow)
        return nil unless workflow

        run_ids = Run.joins(:step).where(steps: { workflow_id: workflow.id }).pluck(:id)
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
