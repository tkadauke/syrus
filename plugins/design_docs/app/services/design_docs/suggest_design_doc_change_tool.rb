require "mcp"

module DesignDocs
  class SuggestDesignDocChangeTool < MCP::Tool
    extend McpToolSupport

    tool_name "suggest_design_doc_change"

    description <<~DESC
      Propose an agent-authored content change to an existing DOC-<id>. Agent writes are suggestion-only: this creates a pending DesignDocSuggestion and never directly mutates canonical Markdown prose.
      Use start_offset/end_offset against rendered Markdown; one call creates one suggestion for one anchored range.
    DESC

    input_schema(
      type: "object",
      required: %w[doc_ref proposed_markdown start_offset end_offset],
      properties: {
        doc_ref: { type: "string", description: doc_ref_description },
        proposed_markdown: { type: "string", description: "Replacement Markdown proposed for the anchored range." },
        start_offset: { type: "integer", description: "Anchor start offset in rendered Markdown." },
        end_offset: { type: "integer", description: "Anchor end offset in rendered Markdown." },
        selected_markdown: { type: "string", description: "Expected original Markdown at the anchored range." },
        change_summary: { type: "string", description: "Short reason for the suggested change." }
      }
    )

    class << self
      def call(chat_session:, server_context:, doc_ref:, proposed_markdown:, start_offset:, end_offset:, selected_markdown: nil, change_summary: nil)
        design_doc = doc_from_ref(doc_ref, scope: readable_scope(user: chat_session.user))
        return error_response("design doc not found or not writable by suggestion in this chat: #{doc_ref}") unless design_doc

        result = CreateSuggestion.call(
          design_doc: design_doc,
          user: chat_session.user,
          actor_kind: "agent",
          attributes: {
            start_offset: start_offset,
            end_offset: end_offset,
            selected_markdown: selected_markdown,
            original_markdown: selected_markdown,
            proposed_markdown: proposed_markdown,
            change_summary: change_summary,
            chat_message_id: current_chat_message_id(server_context)
          }
        )

        ok_response(
          design_doc: design_doc_summary(result.design_doc),
          suggestion: App::DesignDocSerializer.suggestion(result.suggestion),
          reference: result.design_doc.display_id,
          mutation_semantics: "Pending suggestion only; canonical Markdown prose was not directly changed."
        )
      end
    end
  end
end
