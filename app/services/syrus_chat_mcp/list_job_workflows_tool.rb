require "mcp"

module SyrusChatMcp
  class ListJobWorkflowsTool < MCP::Tool
    tool_name "list_job_workflows"

    description "List all Workflows for a Syrus Job in this chat session's repository, newest first."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id whose Workflows should be listed." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job = chat_session.repository.jobs.find_by(id: job_id)
        return SyrusChatMcp.invalid("job not found in this repository: #{job_id}") unless job

        SyrusChatMcp.success(workflows: workflow_index_for(job))
      end

      def workflow_index_for(job)
        job.workflows
          .includes(steps: :runs)
          .reorder(created_at: :desc, id: :desc)
          .map { |workflow| workflow_payload(workflow) }
      end

      def workflow_payload(workflow)
        runs = runs_for(workflow)
        latest_run = runs.max_by { |run| [ run.created_at || Time.at(0), run.id || 0 ] }

        {
          id: workflow.id,
          trigger_kind: workflow.trigger_kind,
          state: workflow.state,
          summary: snippet(workflow.artifact("summary").presence || latest_run&.agent_summary, 300),
          step_count: workflow.steps.size,
          run_count: runs.size,
          started_at: workflow.started_at&.iso8601,
          finished_at: workflow.finished_at&.iso8601
        }
      end

      def runs_for(workflow)
        workflow.steps.flat_map(&:runs)
      end

      def snippet(text, length)
        text.to_s.each_char.first(length).join.presence
      end
    end
  end
end
