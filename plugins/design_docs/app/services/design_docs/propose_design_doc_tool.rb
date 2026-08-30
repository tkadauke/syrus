require "mcp"

module DesignDocs
  class ProposeDesignDocTool < MCP::Tool
    extend ToolSupport

    tool_name "propose_design_doc"

    description "Create a new draft Design Doc and return its DOC-<id> reference. This is for new docs only; chat-agent edits to existing DOC-<id> content must use suggest_design_doc_change and always create pending suggestions."

    input_schema(
      properties: {
        title: { type: "string", description: "Design Doc title." },
        markdown: { type: "string", description: "Initial Markdown for the new design doc." },
        visibility: { type: "string", description: "private or public. Public docs are visible to users who can access an associated repository." },
        repository_ids: { type: "array", items: { type: "integer" }, description: "Repository ids to associate with the doc. In chat contexts these must be attached/accessible repositories." },
        collaborator_user_ids: { type: "array", items: { type: "integer" }, description: "Explicit collaborator user ids for private docs." },
        change_summary: { type: "string", description: "Short summary of the initial proposal." }
      },
      required: %w[title markdown]
    )

    class << self
      def call(title:, markdown:, server_context:, visibility: "private", repository_ids: [], collaborator_user_ids: [], change_summary: nil)
        return invalid("propose_design_doc is only available in chat contexts") unless chat_context?(server_context)

        context = context_from(server_context)
        ids = repository_ids_for(context, repository_ids)
        return invalid("markdown is required") if markdown.to_s.blank?

        result = DesignDocs::Create.call(
          user: context.user,
          attributes: {
            title: title,
            markdown: markdown,
            visibility: visibility.presence || "private",
            repository_ids: ids,
            collaborator_user_ids: collaborator_user_ids,
            origin_chat_session_id: context.chat_session&.id,
            change_summary: change_summary
          },
          actor_kind: "agent"
        )

        success(
          design_doc: detail_payload(result.design_doc),
          doc_ref: result.design_doc.display_id,
          mutation_mode: "new_doc_created",
          note: "For existing DOC-<id> content changes, use suggest_design_doc_change; chat-agent content edits are suggestion-only."
        )
      rescue ActiveRecord::RecordNotFound => e
        invalid(e.message)
      rescue ActiveRecord::RecordInvalid => e
        invalid(e.record.errors.full_messages.to_sentence)
      rescue StandardError => e
        Rails.logger.error("[DesignDocs::ProposeDesignDocTool] #{e.class}: #{e.message}")
        tool_error("Could not propose design doc: #{e.message}")
      end

      private

      def repository_ids_for(context, repository_ids)
        ids = Array(repository_ids).filter_map { |id| Integer(id, exception: false) }.uniq
        return [ context.repository.id ] if ids.empty? && context.repository
        return [] if ids.empty?

        attached_ids = context.allowed_repository_ids
        accessible_ids = Repository.accessible_to(context.user).where(id: ids).pluck(:id)
        raise ActiveRecord::RecordNotFound, "Repository not found in this agent context" unless accessible_ids.sort == ids.sort
        raise ActiveRecord::RecordNotFound, "Repository not attached to this chat context" if attached_ids.any? && (ids - attached_ids).any?

        ids
      end
    end
  end
end
