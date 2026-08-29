require "mcp"

module DesignDocs
  class ProposeDesignDocTool < MCP::Tool
    extend McpToolSupport

    tool_name "propose_design_doc"

    description <<~DESC
      Create a new draft design doc proposal from chat. The response includes its canonical DOC-<id> reference.
      Use this only for new documents; edits to existing DOC-<id> content must go through suggest_design_doc_change so they remain pending owner-reviewed suggestions.
    DESC

    input_schema(
      type: "object",
      required: %w[title markdown],
      properties: {
        title: { type: "string", description: "Design doc title." },
        markdown: { type: "string", description: "Initial Markdown for the new design doc proposal." },
        visibility: { type: "string", enum: DesignDoc::VISIBILITIES, description: "Visibility for the new doc. Defaults to private." },
        repository_ids: { type: "array", items: { type: "integer" }, description: "Repository ids to associate with the new doc." },
        collaborator_user_ids: { type: "array", items: { type: "integer" }, description: "User ids to add as explicit collaborators." },
        change_summary: { type: "string", description: "Short reason for creating the design doc." }
      }
    )

    class << self
      def call(chat_session:, server_context:, title:, markdown:, visibility: nil, repository_ids: [], collaborator_user_ids: [], change_summary: nil)
        result = Create.call(
          user: chat_session.user,
          actor_kind: "agent",
          attributes: {
            title: title,
            markdown: markdown,
            visibility: visibility.presence || "private",
            repository_ids: repository_ids,
            collaborator_user_ids: collaborator_user_ids,
            origin_chat_session_id: chat_session.id,
            change_summary: change_summary
          }
        )

        ok_response(
          design_doc: design_doc_detail(result.design_doc),
          reference: result.design_doc.display_id,
          mutation_semantics: "Created a new design doc proposal. Existing DOC content changes from agents must be suggestions."
        )
      end
    end
  end
end
