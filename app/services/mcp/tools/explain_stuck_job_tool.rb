require "mcp"

module Mcp::Tools
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
        return Mcp::Tools.invalid("job_id is required") unless job_id

        job = job_scope.includes(
          :repository,
          :user,
          :parent_job,
          :epic,
          { dependencies: [ :depends_on_epic, { depends_on_job: [ :repository, :dependencies ] } ] },
          { workflows: { steps: { runs: [ :run_diagnostic, :run_failure_classification, :job_logs ] } } }
        ).find_by(id: job_id)
        return Mcp::Tools.unauthorized("Admin access required") unless job

        Mcp::Tools.success(Admin::StuckJobExplainer.call(job))
      end

      private

      def job_scope
        admin? ? Job.all : current_user.jobs
      end
    end
  end
end
