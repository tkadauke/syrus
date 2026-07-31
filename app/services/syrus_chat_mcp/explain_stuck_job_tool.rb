require "mcp"

module SyrusChatMcp
  class ExplainStuckJobTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "explain_stuck_job"

    description <<~DESC
      Explain why one Syrus Job appears stuck or blocked using Job, Workflow,
      Run, dependency, landing queue, merge-train, and PR metadata. Read-only.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to diagnose." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:)
        job_id = Integer(job_id, exception: false)
        return SyrusChatMcp.invalid("job_id is required") unless job_id

        job = find_job!(
          job_id,
          includes: [
            :repository,
            :user,
            :parent_job,
            :epic,
            { dependencies: [ :depends_on_epic, { depends_on_job: [ :repository, :dependencies ] } ] },
            { workflows: { steps: { runs: [ :run_diagnostic, :run_failure_classification, :job_logs ] } } }
          ]
        )

        SyrusChatMcp.success(Admin::StuckJobExplainer.call(job))
      end
    end
  end
end
