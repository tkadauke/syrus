require "mcp"

module DesignDocs
  class SuggestDesignDocChangeTool < MCP::Tool
    extend ToolSupport

    tool_name "suggest_design_doc_change"

    description "Suggest a change to existing DOC-<id> content. Chat-agent content writes are suggestion-only: this always creates a pending suggestion and never directly mutates canonical Markdown."

    input_schema(
      properties: {
        doc_ref: { type: "string", description: "Canonical Design Doc reference such as DOC-123." },
        start_offset: { type: "integer", description: "Rendered Markdown start offset for the changed range." },
        end_offset: { type: "integer", description: "Rendered Markdown end offset for the changed range." },
        original_markdown: { type: "string", description: "Original rendered Markdown in the selected range." },
        proposed_markdown: { type: "string", description: "Replacement Markdown for the selected range. The owner must accept the pending suggestion before it becomes canonical." },
        change_summary: { type: "string", description: "Short summary of the suggested change." },
        thread_id: { type: "integer", description: "Optional existing design-doc thread id to attach the suggestion to." }
      },
      required: %w[doc_ref start_offset end_offset proposed_markdown]
    )

    class << self
      def call(doc_ref:, start_offset:, end_offset:, proposed_markdown:, server_context:, original_markdown: nil, change_summary: nil, thread_id: nil)
        return invalid("suggest_design_doc_change is only available in chat contexts") unless chat_context?(server_context)

        context = context_from(server_context)
        design_doc = find_design_doc!(doc_ref, context)
        result = DesignDocs::CreateSuggestion.call(
          design_doc: design_doc,
          user: context.user,
          actor_kind: "agent",
          attributes: {
            start_offset: start_offset,
            end_offset: end_offset,
            original_markdown: original_markdown,
            proposed_markdown: proposed_markdown,
            change_summary: change_summary,
            thread_id: thread_id
          }.merge(agent_actor_attributes(server_context))
        )

        success(suggestion_payload(result))
      rescue ActiveRecord::RecordNotFound
        invalid("design doc not found in this agent context: #{doc_ref}. Use DOC-<id> references from list_design_docs.")
      rescue ActiveRecord::RecordInvalid => e
        invalid(e.record.errors.full_messages.to_sentence)
      rescue Pundit::NotAuthorizedError
        invalid("not allowed to suggest changes to #{doc_ref}")
      rescue StandardError => e
        Rails.logger.error("[DesignDocs::SuggestDesignDocChangeTool] #{e.class}: #{e.message}")
        tool_error("Could not suggest design doc change: #{e.message}")
      end
    end
  end
end
