require "mcp"

module DesignDocs
  class CommentOnDesignDocTool < MCP::Tool
    extend McpToolSupport

    tool_name "comment_on_design_doc"

    description <<~DESC
      Add an agent-authored inline comment to a readable DOC-<id>. This inserts hidden Syrus anchor markers but does not directly rewrite canonical prose.
      Use start_offset/end_offset against rendered Markdown, not marker-inclusive stored Markdown.
    DESC

    input_schema(
      type: "object",
      required: %w[doc_ref body start_offset end_offset],
      properties: {
        doc_ref: { type: "string", description: doc_ref_description },
        body: { type: "string", description: "Comment body." },
        start_offset: { type: "integer", description: "Anchor start offset in rendered Markdown." },
        end_offset: { type: "integer", description: "Anchor end offset in rendered Markdown." },
        selected_markdown: { type: "string", description: "Expected selected Markdown at the anchored range." }
      }
    )

    class << self
      def call(chat_session:, server_context:, doc_ref:, body:, start_offset:, end_offset:, selected_markdown: nil)
        design_doc = doc_from_ref(doc_ref, scope: readable_scope(user: chat_session.user))
        return error_response("design doc not found or not writable by suggestion in this chat: #{doc_ref}") unless design_doc

        result = CreateComment.call(
          design_doc: design_doc,
          user: chat_session.user,
          actor_kind: "agent",
          attributes: {
            body: body,
            start_offset: start_offset,
            end_offset: end_offset,
            selected_markdown: selected_markdown
          }
        )

        ok_response(
          design_doc: design_doc_summary(result.design_doc),
          thread: App::DesignDocSerializer.thread(result.thread),
          comment: App::DesignDocSerializer.comment(result.comment),
          reference: result.design_doc.display_id
        )
      end
    end
  end
end
