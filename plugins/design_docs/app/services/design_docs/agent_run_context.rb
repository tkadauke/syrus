module DesignDocs
  class AgentRunContext
    CHAT_MESSAGE_LIMIT = 8

    def initialize(design_doc:, thread:, triggering_comment:, requested_by_user:)
      @design_doc = design_doc
      @thread = thread
      @triggering_comment = triggering_comment
      @requested_by_user = requested_by_user
    end

    def to_h
      {
        design_doc: design_doc_payload,
        thread: thread_payload,
        pending_suggestions: pending_suggestions_payload,
        owner: user_payload(design_doc.owner_user),
        collaborators: design_doc.collaborator_users.map { |user| user_payload(user) },
        repositories: design_doc.repositories.map { |repository| repository_payload(repository) },
        requested_by: user_payload(requested_by_user),
        origin_chat: origin_chat_payload
      }.compact
    end

    private

    attr_reader :design_doc, :thread, :triggering_comment, :requested_by_user

    def design_doc_payload
      {
        id: design_doc.id,
        doc_ref: design_doc.display_id,
        title: design_doc.title,
        visibility: design_doc.visibility,
        state: design_doc.state,
        current_version_id: design_doc.current_version_id,
        current_version_number: design_doc.current_version&.version_number,
        markdown: design_doc.markdown,
        rendered_markdown: DesignDocs::AnchorMarkers.strip(design_doc.markdown)
      }
    end

    def thread_payload
      {
        id: thread.id,
        state: thread.state,
        anchor: DesignDocs::Serializer.send(:anchor_json, thread.anchor),
        triggering_comment_id: triggering_comment.id,
        comments: thread.comments.includes(:author_user).order(:created_at, :id).map do |comment|
          {
            id: comment.id,
            author_kind: comment.author_kind,
            author: user_payload(comment.author_user),
            body: comment.body,
            created_at: comment.created_at.iso8601
          }
        end
      }
    end

    def pending_suggestions_payload
      thread.suggestions.where(state: "pending").includes(:anchor, :suggested_by_user).order(:created_at, :id).map do |suggestion|
        {
          id: suggestion.id,
          original_markdown: suggestion.original_markdown,
          proposed_markdown: suggestion.proposed_markdown_value,
          change_summary: suggestion.change_summary,
          suggested_by_kind: suggestion.suggested_by_kind,
          suggested_by: user_payload(suggestion.suggested_by_user),
          provenance: suggestion.provenance || {},
          created_at: suggestion.created_at.iso8601
        }
      end
    end

    def origin_chat_payload
      chat = design_doc.origin_chat_session
      return nil unless chat

      {
        id: chat.id,
        title: chat.title,
        messages: chat.messages.order(created_at: :desc, id: :desc).limit(CHAT_MESSAGE_LIMIT).reverse.map do |message|
          { id: message.id, role: message.role, text: message_text(message), created_at: message.created_at.iso8601 }
        end
      }
    end

    def message_text(message)
      content = message.content
      return content.to_s if content.is_a?(String)

      content&.fetch("text", nil).to_s
    end

    def user_payload(user)
      return nil unless user

      { id: user.id, name: user.display_name, email_address: user.email_address }
    end

    def repository_payload(repository)
      { id: repository.id, slug: repository.slug }
    end
  end
end
