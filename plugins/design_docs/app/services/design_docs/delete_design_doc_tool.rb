require "mcp"

module DesignDocs
  class DeleteDesignDocTool < MCP::Tool
    extend ToolSupport
    extend ::Mcp::Tools::ProposalToolSupport

    FAST_PATH_MAX_AGE = 10.minutes

    tool_name "delete_design_doc"

    description "Archive a DOC-<id> Design Doc. Despite the name, this never physically deletes docs, versions, comments, suggestions, anchors, or repository links. Fresh empty v1 docs are archived immediately; all other docs require pending operator confirmation."

    input_schema(
      properties: {
        doc_ref: { type: "string", description: "Canonical Design Doc reference such as DOC-123. A bare numeric id is accepted only for compatibility." },
        reason: { type: "string", description: "Short reason for archiving this Design Doc." }
      },
      required: %w[doc_ref]
    )

    class << self
      def call(doc_ref:, server_context:, reason: nil)
        return invalid("delete_design_doc is only available in chat contexts") unless chat_context?(server_context)

        context = context_from(server_context)
        design_doc = find_design_doc!(doc_ref, context)
        return invalid("not allowed to archive #{design_doc.display_id}") unless DesignDocPolicy.new(context.user, design_doc).archive?

        if fast_path?(design_doc)
          result = Archive.call(design_doc: design_doc, user: context.user, audit_reason: reason.presence || "Fast-path delete_design_doc archive")
          return success(
            archived: true,
            immediate: true,
            doc_ref: result.design_doc.display_id,
            title: result.design_doc.title,
            previous_state: result.previous_state,
            new_state: result.new_state,
            reason: reason.presence || "Fresh version 1 design doc with no comments, threads, or suggestions was archived immediately."
          )
        end

        pending_action = create_pending_action_for_current_message!(
          server_context,
          context.chat_session,
          action: "delete_design_doc",
          requested_by: "agent",
          reason: reason,
          payload: audit_payload(design_doc)
        )

        success(
          pending_confirmation_id: pending_action.id,
          pending_action_id: pending_action.id,
          state: pending_action.state,
          message: "Archive #{design_doc.display_id}?",
          doc_ref: design_doc.display_id,
          title: design_doc.title,
          confirmation_required: true,
          confirmation_reason: confirmation_reason(design_doc)
        )
      rescue ActiveRecord::RecordNotFound
        invalid("design doc not found in this agent context: #{doc_ref}. Use DOC-<id> references from list_design_docs.")
      rescue Pundit::NotAuthorizedError
        invalid("not allowed to archive #{doc_ref}")
      rescue StandardError => e
        Rails.logger.error("[DesignDocs::DeleteDesignDocTool] #{e.class}: #{e.message}")
        tool_error("Could not archive design doc: #{e.message}")
      end

      private

      def fast_path?(design_doc)
        current_version_number(design_doc) == 1 &&
          design_doc.created_at >= FAST_PATH_MAX_AGE.ago &&
          design_doc.threads.count.zero? &&
          comments_count(design_doc).zero? &&
          design_doc.suggestions.count.zero?
      end

      def audit_payload(design_doc)
        {
          doc_ref: design_doc.display_id,
          design_doc_id: design_doc.id,
          title: design_doc.title,
          state: design_doc.state,
          age: distance_of_time_in_words(design_doc.created_at, Time.current),
          age_seconds: (Time.current - design_doc.created_at).to_i,
          current_version_number: current_version_number(design_doc),
          threads_count: design_doc.threads.count,
          comments_count: comments_count(design_doc),
          suggestions_count: design_doc.suggestions.count,
          repository_ids: design_doc.repositories.pluck(:id),
          repository_slugs: design_doc.repositories.map(&:slug),
          confirmation_reason: confirmation_reason(design_doc)
        }
      end

      def confirmation_reason(design_doc)
        reasons = []
        reasons << "current version is v#{current_version_number(design_doc) || "unknown"}" unless current_version_number(design_doc) == 1
        reasons << "doc is older than 10 minutes" if design_doc.created_at < FAST_PATH_MAX_AGE.ago
        reasons << "doc has #{design_doc.threads.count} thread(s)" if design_doc.threads.exists?
        reasons << "doc has #{comments_count(design_doc)} comment(s)" if comments_count(design_doc).positive?
        reasons << "doc has #{design_doc.suggestions.count} suggestion(s)" if design_doc.suggestions.exists?
        reasons.presence&.to_sentence || "confirmation required before archiving"
      end

      def current_version_number(design_doc)
        design_doc.current_version&.version_number
      end

      def comments_count(design_doc)
        DesignDocs::DesignDocComment.joins(:thread).where(design_doc_threads: { design_doc_id: design_doc.id }).count
      end

      def distance_of_time_in_words(...)
        ActionController::Base.helpers.distance_of_time_in_words(...)
      end
    end
  end
end
