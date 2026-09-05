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

      def detail(design_doc, user: nil)
        summary(design_doc).merge(
          markdown: design_doc.markdown,
          rendered_markdown: DesignDocs::AnchorMarkers.strip(design_doc.markdown),
          permissions: permissions_json(design_doc, user),
          collaborator_ids: design_doc.collaborator_users.map(&:id),
          collaborators: design_doc.collaborator_users.map { |user| user_json(user) },
          pending_suggestions_count: design_doc.suggestions.where(state: "pending").count,
          open_threads_count: design_doc.threads.where(state: "open").count,
          threads: design_doc.threads.includes(:anchor, :agent_runs, comments: [ :author_user, :agent_run ]).order(:created_at, :id).map { |thread| self.thread(thread) },
          suggestions: design_doc.suggestions
            .includes(:anchor, :agent_run, :suggested_by_user, :reviewed_by_user, thread: [ :anchor, :agent_runs, { comments: [ :author_user, :agent_run ] } ])
            .order(created_at: :desc, id: :desc)
            .map { |suggestion| self.suggestion(suggestion) }
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
          proposed_markdown: suggestion.proposed_markdown_value,
          change_type: suggestion.change_type,
          render_mode: suggestion.render_mode,
          change_summary: suggestion.change_summary,
          base_version_id: suggestion.base_version_id,
          design_doc_agent_run_id: suggestion.design_doc_agent_run_id,
          provenance: suggestion.provenance || {},
          conflict_reason: suggestion.conflict_reason,
          anchor: anchor_json(suggestion.anchor),
          thread: suggestion.thread ? thread(suggestion.thread) : nil,
          reviewed_by: user_json(suggestion.reviewed_by_user),
          reviewed_at: suggestion.reviewed_at&.iso8601,
          created_at: suggestion.created_at.iso8601
        }
      end

      def thread(thread)
        {
          id: thread.id,
          state: thread.state,
          anchor: anchor_json(thread.anchor),
          opened_by: user_json(thread.opened_by_user),
          resolved_by: user_json(thread.resolved_by_user),
          resolved_at: thread.resolved_at&.iso8601,
          agent_run: agent_run_json(latest_agent_run(thread)),
          comments: ordered_comments(thread).map { |comment| comment_json(comment) },
          created_at: thread.created_at.iso8601,
          updated_at: thread.updated_at.iso8601
        }
      end

      def comment(comment)
        comment_json(comment)
      end

      # Lightweight payload for the DOC-<id> hover/click preview popup.
      # Deliberately excludes the full markdown/threads/suggestions payload
      # `detail` carries, since a chat message can reference many DOC slugs
      # at once.
      def preview(design_doc)
        {
          id: design_doc.id,
          display_id: design_doc.display_id,
          accessible: true,
          title: design_doc.title,
          visibility: design_doc.visibility,
          state: design_doc.state,
          owner: user_json(design_doc.owner_user),
          collaborators: design_doc.collaborator_users.map { |user| user_json(user) },
          comments_count: design_doc.comments_count,
          latest_version_number: design_doc.current_version&.version_number,
          updated_at: design_doc.updated_at.iso8601,
          preview_text: design_doc.preview_text
        }
      end

      # Rendered when the doc doesn't exist or the current viewer can't see
      # it. Carries only the slug so the popup can render a minimal
      # "not accessible" state without leaking title, owner, or content.
      def unavailable_preview(id)
        {
          id: id.to_i,
          display_id: "DOC-#{id}",
          accessible: false
        }
      end

      private

      def permissions_json(design_doc, user)
        return { can_write_canonical: false, can_suggest: false, can_review_suggestions: false } unless user

        policy = DesignDocPolicy.new(user, design_doc)
        {
          can_write_canonical: policy.canonical_write?,
          can_suggest: policy.suggest?,
          can_review_suggestions: policy.review?
        }
      end

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
          marker_id: anchor.marker_id,
          anchor_kind: anchor.anchor_kind,
          status: anchor.status,
          start_offset: anchor.start_offset,
          end_offset: anchor.end_offset,
          last_known_start_offset: anchor.last_known_start_offset,
          last_known_end_offset: anchor.last_known_end_offset,
          selected_markdown: anchor.selected_markdown,
          selected_text: anchor.selected_text,
          prefix_context: anchor.prefix_context,
          suffix_context: anchor.suffix_context
        }
      end

      def comment_json(comment)
        {
          id: comment.id,
          author_kind: comment.author_kind,
          author: user_json(comment.author_user),
          design_doc_agent_run_id: comment.design_doc_agent_run_id,
          body: comment.body,
          created_at: comment.created_at.iso8601,
          updated_at: comment.updated_at.iso8601
        }
      end

      def ordered_comments(thread)
        comments = thread.association(:comments).loaded? ? thread.comments.to_a : thread.comments
        comments.sort_by { |comment| [ comment.created_at || Time.zone.at(0), comment.id || 0 ] }
      end

      def latest_agent_run(thread)
        runs = thread.association(:agent_runs).loaded? ? thread.agent_runs.to_a : thread.agent_runs
        runs.max_by { |run| [ run.created_at || Time.zone.at(0), run.id || 0 ] }
      end

      def agent_run_json(run)
        return nil unless run

        {
          id: run.id,
          status: run.status,
          triggering_comment_id: run.triggering_comment_id,
          requested_by: user_json(run.requested_by_user),
          agent_provider: run.agent_provider,
          base_version_id: run.base_version_id,
          result_summary: run.result_summary,
          error_message: run.error_message,
          started_at: run.started_at&.iso8601,
          finished_at: run.finished_at&.iso8601,
          created_at: run.created_at.iso8601,
          updated_at: run.updated_at.iso8601
        }
      end
    end
  end
end
