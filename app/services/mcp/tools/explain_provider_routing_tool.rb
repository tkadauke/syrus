require "mcp"

module Mcp::Tools
  class ExplainProviderRoutingTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "explain_provider_routing"
    description "Explain effective first-match provider routing for an accessible Job, including scope precedence, disabled skips, match evidence, the winning route or hold, active holds, and an explicit Job pin that overrides rules."

    input_schema(
      properties: {
        job_id: { type: "integer" },
        task_key: { type: "string" },
        trigger: { type: "object" },
        workflow_trigger_kind: { type: "string" }
      },
      required: %w[job_id task_key]
    )

    class << self
      def call(job_id:, task_key:, server_context:, trigger: nil, workflow_trigger_kind: nil)
        job = find_job!(job_id, includes: [ :repository, :owner_user, :user ])
        Mcp::Tools.success(
          ProviderRouting::Explainer.call(
            job: job,
            task_key: task_key,
            trigger: trigger,
            workflow_trigger_kind: workflow_trigger_kind
          )
        )
      end
    end
  end
end
