require "mcp"

module SyrusChatMcp
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
            { dependencies: [ { depends_on_job: :repository }, :depends_on_epic ] },
            { workflows: { steps: { runs: :job_logs } } }
          ]
        )

        workflow = job.latest_workflow
        workflows_index = job.workflows
                             .includes(steps: :runs)
                             .reorder(created_at: :desc, id: :desc)
                             .map { |wf| workflow_index_payload(wf) }
        SyrusChatMcp.success(
          job: job_detail_payload(job),
          workflow_count: workflows_index.size,
          workflows_index: workflows_index,
          latest_workflow: workflow_summary_payload(workflow),
          transcript: transcript_payload(workflow)
        )
      end

      private

      def transcript_payload(workflow)
        return nil unless workflow

        transcript = workflow.steps.flat_map do |step|
          step.runs.flat_map do |run|
            run.job_logs.map { |log| log.chunk.to_s }
          end
        end.join

        SyrusChatMcp.head_tail(transcript)
      end
    end
  end
end
