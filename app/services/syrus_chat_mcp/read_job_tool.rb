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
      def call(job_id:, server_context:)
        job = find_job!(
          job_id,
          includes: [
            { dependencies: [ { depends_on_job: :repository }, :depends_on_epic ] },
            { workflows: { steps: { runs: :job_logs } } }
          ]
        )

        workflow = job.latest_workflow
        workflows_index = SyrusChatMcp::ListJobWorkflowsTool.workflow_index_for(job)
        SyrusChatMcp.success(
          job: job_payload(job),
          workflow_count: workflows_index.size,
          workflows_index: workflows_index,
          latest_workflow: workflow_payload(workflow),
          transcript: transcript_payload(workflow)
        )
      end

      private

      def job_payload(job)
        {
          id: job.id,
          kind: job.kind,
          issue_number: job.issue_number,
          pr_number: job.pr_number || job.external_pr_number,
          internal_pr_number: job.pr_number,
          external_pr_number: job.external_pr_number,
          branch_name: job.branch_name,
          state: job.state,
          closure_reason: job.closure_reason,
          agent_provider: job.agent_provider,
          priority: job.priority,
          issue_title: job.issue_title,
          dependencies: job.dependencies.order(:id).filter_map { |dependency| dependency_reference(dependency) },
          created_at: job.created_at&.iso8601,
          updated_at: job.updated_at&.iso8601
        }
      end

      def dependency_reference(dependency)
        if dependency.pending?
          {
            pending: true,
            unresolved_ref: dependency.unresolved_slug,
            source: dependency.source
          }
        elsif dependency.depends_on_job
          job_reference(dependency.depends_on_job)
        end
      end

      def job_reference(job)
        {
          id: job.id,
          issue_number: job.issue_number,
          issue_title: job.issue_title,
          state: job.state,
          repository: job.repository.slug
        }
      end

      def workflow_payload(workflow)
        return nil unless workflow

        latest_run = workflow.runs.last
        {
          id: workflow.id,
          trigger_kind: workflow.trigger_kind,
          state: workflow.state,
          agent_provider: workflow.agent_provider,
          summary: workflow.artifact("summary").presence || latest_run&.agent_summary,
          created_at: workflow.created_at&.iso8601,
          finished_at: workflow.finished_at&.iso8601
        }
      end

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
