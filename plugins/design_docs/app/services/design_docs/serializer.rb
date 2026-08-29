module DesignDocs
  class Serializer
    class << self
      def summary(design_doc)
        {
          id: design_doc.id,
          display_id: design_doc.display_id,
          title: design_doc.title,
          visibility: design_doc.visibility,
          state: design_doc.state,
          owner: user_json(design_doc.owner_user),
          repository_ids: design_doc.repositories.map(&:id),
          repositories: design_doc.repositories.map { |repository| repository_json(repository) },
          current_version_number: design_doc.current_version&.version_number,
          origin_chat_session_id: design_doc.origin_chat_session_id,
          updated_at: design_doc.updated_at.iso8601,
          created_at: design_doc.created_at.iso8601
        }
      end

      def detail(design_doc)
        summary(design_doc).merge(
          markdown: design_doc.markdown,
          collaborator_ids: design_doc.collaborator_users.map(&:id),
          collaborators: design_doc.collaborator_users.map { |user| user_json(user) },
          pending_suggestions_count: design_doc.suggestions.where(state: "pending").count
        )
      end

      def version(version)
        {
          id: version.id,
          version_number: version.version_number,
          markdown: version.markdown,
          actor_kind: version.actor_kind,
          actor: user_json(version.actor_user),
          change_summary: version.change_summary,
          metadata: version.metadata || {},
          created_at: version.created_at.iso8601
        }
      end

      def suggestion(suggestion)
        {
          id: suggestion.id,
          state: suggestion.state,
          suggested_by_kind: suggestion.suggested_by_kind,
          suggested_by: user_json(suggestion.suggested_by_user),
          original_markdown: suggestion.original_markdown,
          suggested_markdown: suggestion.suggested_markdown,
          change_summary: suggestion.change_summary,
          anchor: anchor_json(suggestion.anchor),
          created_at: suggestion.created_at.iso8601
        }
      end

      private

      def user_json(user)
        return nil unless user

        {
          id: user.id,
          name: user.display_name,
          email_address: user.email_address
        }
      end

      def repository_json(repository)
        {
          id: repository.id,
          slug: repository.slug
        }
      end

      def anchor_json(anchor)
        {
          id: anchor.id,
          anchor_key: anchor.anchor_key,
          start_offset: anchor.start_offset,
          end_offset: anchor.end_offset,
          selected_markdown: anchor.selected_markdown
        }
      end
    end
  end
end
