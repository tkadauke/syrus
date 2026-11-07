require "mcp"

module DesignDocs
  module ToolSupport
    def success(payload)
      Mcp::Tools.success(payload)
    end

    def invalid(message)
      Mcp::Tools.invalid(message)
    end

    def tool_error(message)
      Mcp::Tools.tool_error(message)
    end

    def symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end

    def context_from(server_context)
      McpToolContext.from_server_context(server_context)
    end

    def chat_context?(server_context)
      server_context&.key?(:chat_session)
    end

    def agent_actor_attributes(server_context)
      context = context_from(server_context)
      attrs = {}
      attrs[:run_id] = context.run.id if context.run
      attrs[:workflow_id] = context.workflow.id if context.workflow
      attrs[:chat_message_id] = server_context[:current_message].id if server_context[:current_message]&.respond_to?(:id)
      attrs
    end

    def visible_scope(context)
      scope = DesignDocs::DesignDoc.visible_to(context.user)
      return workflow_scope(scope, context) if context.run?

      scope
    end

    def scoped_repository(context, repository_id)
      return context.repository if context.run?
      return nil if repository_id.blank?

      ids = context.allowed_repository_ids
      repository = Repository.accessible_to(context.user).find_by(id: repository_id)
      return repository if repository && (ids.empty? || ids.include?(repository.id))

      nil
    end

    def find_design_doc!(doc_ref, context)
      id = parse_doc_ref(doc_ref)
      raise ActiveRecord::RecordNotFound, "Design doc not found" unless id

      visible_scope(context).find(id)
    end

    def parse_doc_ref(doc_ref)
      DesignDocs::DocRef.parse(doc_ref)
    end

    def list_payload(design_doc)
      {
        id: design_doc.id,
        doc_ref: design_doc.display_id,
        title: design_doc.title,
        visibility: design_doc.visibility,
        state: design_doc.state,
        repository_ids: design_doc.repositories.map(&:id),
        current_version_number: design_doc.current_version&.version_number,
        updated_at: design_doc.updated_at.iso8601
      }
    end

    def detail_payload(design_doc, context:, page: nil)
      page ||= DesignDocs::ReadPage.call(design_doc: design_doc)
      base = if page.first_page
        DesignDocs::Serializer.detail(design_doc, user: permissions_user(context))
      else
        metadata_payload(design_doc)
      end

      base.merge(
        doc_ref: design_doc.display_id,
        version_number: page.version.version_number,
        markdown: page.markdown,
        rendered_markdown: page.rendered_markdown,
        total_bytes: page.total_bytes,
        start_offset: page.start_offset,
        end_offset: page.end_offset,
        truncated: page.truncated,
        next_cursor: page.next_cursor,
        discussion_included: page.first_page
      )
    end

    def metadata_payload(design_doc)
      {
        doc_ref: design_doc.display_id,
        title: design_doc.title,
        state: design_doc.state,
        visibility: design_doc.visibility,
        current_version_number: DesignDocs::DesignDocVersion.where(id: design_doc.current_version_id).pick(:version_number),
        pending_suggestions_count: DesignDocs::DesignDocSuggestion.where(design_doc_id: design_doc.id, state: "pending").count,
        open_threads_count: DesignDocs::DesignDocThread.where(design_doc_id: design_doc.id, state: "open").count,
        updated_at: design_doc.updated_at.iso8601
      }
    end

    def suggestion_payload(result)
      {
        design_doc: list_payload(result.design_doc),
        doc_ref: result.design_doc.display_id,
        suggestion: DesignDocs::Serializer.suggestion(result.suggestion),
        version: DesignDocs::Serializer.version(result.version),
        mutation_mode: "suggestion_only"
      }
    end

    private

    # Workflow agents have no design-doc mutation tools registered, so their
    # permissions payload must stay all-false regardless of what the
    # underlying job owner is actually allowed to do -- reporting the real
    # policy result there would advertise capabilities the agent can't act on.
    def permissions_user(context)
      context.user if context.chat?
    end

    def workflow_scope(scope, context)
      return scope.none unless context.repository

      scope.joins(:design_doc_repositories)
        .where(design_doc_repositories: { repository_id: context.repository.id })
    end
  end
end
