require "mcp"

module Mcp::Tools
  class InspectWorkflowOutcomeOverridesTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "inspect_workflow_outcome_overrides"
    description "Inspect technically overridable failed review and grader evidence for a visible Syrus Job. Returns exact, revision-bound candidates and their consequences; it does not change workflow state."
    input_schema(properties: { job_id: { type: "integer", description: "Syrus Job id." } }, required: %w[job_id])

    class << self
      include JobLifecycleToolSupport

      def call(job_id:, server_context:)
        job = find_job!(job_id)
        Mcp::Tools.success(job_id: job.id, candidates: WorkflowOutcomeOverrides::CandidateResolver.for_job(job).map(&:as_json))
      rescue WorkflowOutcomeOverrides::CandidateResolver::NotFound => error
        Mcp::Tools.invalid(error.message)
      end
    end
  end
end
