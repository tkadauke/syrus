require "mcp"

module Mcp::Tools
  class ReadWorkflowTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "read_workflow"

    description "Read Workflow metadata, Steps, and per-Step Run summaries for a Workflow visible to this chat session's user."

    input_schema(
      properties: {
        workflow_id: { type: "integer", description: "Syrus Workflow id to inspect." },
        step_id: { type: "integer", description: "Include the details excerpt (e.g. grader output) for this one Step. Omitted by default." },
        include_details: { type: "boolean", description: "Include the details excerpt for every Step. Can be large; prefer step_id." }
      },
      required: %w[workflow_id]
    )

    class << self
      include McpToolPayloads::WorkflowPayload

      def call(workflow_id:, server_context:, step_id: nil, include_details: false)
        workflow = find_workflow!(workflow_id, includes: { steps: :runs })

        Mcp::Tools.success(workflow: workflow_detail_payload(workflow, step_id: step_id, include_details: include_details))
      end

      private

      def workflow_detail_payload(workflow, step_id: nil, include_details: false)
        runs = workflow_step_runs(workflow)
        latest_run = latest_run_for(runs)

        {
          id: workflow.id,
          job_id: workflow.job_id,
          trigger_kind: workflow.trigger_kind,
          state: workflow.state,
          agent_provider: workflow.agent_provider,
          summary: text_snippet(workflow.artifact("summary").presence || latest_run&.agent_summary, 300),
          step_count: workflow.steps.size,
          run_count: runs.size,
          total_cost_usd: decimal_payload(workflow.total_cost_usd),
          created_at: workflow.created_at&.iso8601,
          started_at: workflow.started_at&.iso8601,
          finished_at: workflow.finished_at&.iso8601,
          cancellation: Workflows::CancellationAttribution.payload_for(workflow),
          steps: workflow.steps.map { |step| step_payload(step, with_details: include_details || step.id == step_id) }
        }.then { |h| without_blank_cancellation(h) }
      end

      def step_payload(step, with_details: false)
        {
          id: step.id,
          kind: step.kind,
          state: step.state,
          position: step.position,
          details: (step.details.presence if with_details),
          details_bytes: step.details.present? ? step.details.to_json.bytesize : 0,
          run_count: step.runs.size,
          started_at: step.started_at&.iso8601,
          finished_at: step.finished_at&.iso8601,
          runs: step.runs.map { |run| run_detail_payload(run) }
        }
      end

      def run_detail_payload(run)
        {
          id: run.id,
          state: run.state,
          agent_outcome: run.agent_outcome,
          agent_summary: text_snippet(run.agent_summary, 500),
          started_at: run.started_at&.iso8601,
          finished_at: run.finished_at&.iso8601,
          cost_usd: decimal_payload(run.cost_usd),
          cancellation: Workflows::CancellationAttribution.run_payload(run)
        }.then { |h| without_blank_cancellation(h) }
      end

      def decimal_payload(value)
        return nil if value.nil?

        value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s
      end
    end
  end
end
