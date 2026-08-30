require "mcp"

module DesignDocs
  class CommentOnDesignDocTool < MCP::Tool
    extend ToolSupport

    tool_name "comment_on_design_doc"

    description "Create an agent-authored inline comment on a DOC-<id> Design Doc. The comment is anchored by rendered Markdown offsets; it never mutates canonical content except hidden Syrus anchor markers."

    input_schema(
      properties: {
        doc_ref: { type: "string", description: "Canonical Design Doc reference such as DOC-123." },
        body: { type: "string", description: "Comment body." },
        start_offset: { type: "integer", description: "Rendered Markdown start offset for the anchor." },
        end_offset: { type: "integer", description: "Rendered Markdown end offset for the anchor." },
        selected_markdown: { type: "string", description: "Rendered Markdown selected by the offset range, used to stabilize the anchor." }
      },
      required: %w[doc_ref body start_offset end_offset]
    )

    class << self
      def call(doc_ref:, body:, start_offset:, end_offset:, server_context:, selected_markdown: nil)
        return invalid("comment_on_design_doc is only available in chat contexts") unless chat_context?(server_context)

        context = context_from(server_context)
        design_doc = find_design_doc!(doc_ref, context)
        result = DesignDocs::CreateComment.call(
          design_doc: design_doc,
          user: context.user,
          actor_kind: "agent",
          attributes: {
            body: body,
            start_offset: start_offset,
            end_offset: end_offset,
            selected_markdown: selected_markdown
          }.merge(agent_actor_attributes(server_context))
        )

        success(
          design_doc: list_payload(result.design_doc),
          doc_ref: result.design_doc.display_id,
          thread: DesignDocs::Serializer.thread(result.thread),
          comment: DesignDocs::Serializer.comment(result.comment),
          version: DesignDocs::Serializer.version(result.version),
          mutation_mode: "comment_only"
        )
      rescue ActiveRecord::RecordNotFound
        invalid("design doc not found in this agent context: #{doc_ref}. Use DOC-<id> references from list_design_docs.")
      rescue ActiveRecord::RecordInvalid => e
        invalid(e.record.errors.full_messages.to_sentence)
      rescue Pundit::NotAuthorizedError
        invalid("not allowed to comment on #{doc_ref}")
      rescue StandardError => e
        Rails.logger.error("[DesignDocs::CommentOnDesignDocTool] #{e.class}: #{e.message}")
        tool_error("Could not comment on design doc: #{e.message}")
      end
    end
  end
end
