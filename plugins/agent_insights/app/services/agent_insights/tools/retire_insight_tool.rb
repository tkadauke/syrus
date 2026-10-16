require "mcp"

module AgentInsights
  module Tools
    class RetireInsightTool < MCP::Tool
      extend MutationToolSupport

      tool_name "retire_insight"
      description "Retire one insight, or request one operator confirmation for a validated batch. Accepted history requires retire_accepted: true. Batch superseding references are maps keyed by the retired insight id."
      input_schema(properties: {
        target_insight_id: { type: "integer", description: "One insight id (backward-compatible interface)." },
        insight_ids: { type: "array", items: { type: "integer" }, description: "Insight ids for one grouped confirmation." },
        reason: { type: "string", description: "Required shared audit reason." },
        superseded_by_insight_id: { type: "integer", description: "Optional singular superseding insight id." },
        superseded_by_job_id: { type: "integer", description: "Optional singular superseding Job id." },
        superseded_by_insight_ids: { type: "object", description: "Map from retired insight id to superseding insight id." },
        superseded_by_job_ids: { type: "object", description: "Map from retired insight id to superseding Job id." },
        retire_accepted: { type: "boolean", description: "Explicitly allow accepted targets to be retired." }
      }, required: %w[reason])

      class << self
        def call(target_insight_id: nil, insight_ids: nil, reason:, server_context:, superseded_by_insight_id: nil,
                 superseded_by_job_id: nil, superseded_by_insight_ids: {}, superseded_by_job_ids: {}, retire_accepted: false)
          ids, error = Mutations::Base.validate_ids(id: target_insight_id, ids: insight_ids, singular_name: "target_insight_id")
          return Mcp::Tools.invalid(error) if error

          insight_refs = references(ids, superseded_by_insight_id, superseded_by_insight_ids)
          job_refs = references(ids, superseded_by_job_id, superseded_by_job_ids)
          _context, chat, actor, scope = mutation_context(server_context)
          mutation = Mutations::Retire.new(ids: ids, actor: actor, repository_scope: scope, reason: reason,
            retire_accepted: retire_accepted, superseded_by_insight_ids: insight_refs, superseded_by_job_ids: job_refs)
          response = execute_or_confirm(mutation: mutation, ids: ids, chat_session: chat, server_context: server_context,
            action: "retire_insights",
            payload: { "insight_ids" => ids, "reason" => reason, "retire_accepted" => retire_accepted,
              "superseded_by_insight_ids" => insight_refs, "superseded_by_job_ids" => job_refs },
            message: "Retire insights #{ids.map { |id| "##{id}" }.join(', ')}?")
          append_workflow_artifact(_context.run, mutation.validate.suggestions.first) if ids.one? && _context.run? && !response.error?
          response
        rescue StandardError => e
          Rails.logger.error("[AgentInsights::Tools::RetireInsightTool] #{e.class}: #{e.message}")
          MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
        end

        private

        def references(ids, singular, plural)
          refs = plural.to_h
          singular.present? ? refs.merge(ids.first.to_s => singular) : refs
        end


        def append_workflow_artifact(run, insight)
          retirements = Array(run.workflow.artifact("insight_retirements"))
          retirements << { "id" => insight.id, "title" => insight.title, "reason" => insight.retired_reason,
            "superseded_by_insight_id" => insight.superseded_by_insight_id, "superseded_by_job_id" => insight.superseded_by_job_id }
          run.workflow.set_artifact!("insight_retirements", retirements)
          Mcp::Tools.write_log(run, "[mcp] retire_insight: ##{insight.id} #{insight.title.truncate(80)}")
        end
      end
    end
  end
end
