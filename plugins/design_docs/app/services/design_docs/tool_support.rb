require "mcp"

module DesignDocs
  module ToolSupport
    MAX_MARKDOWN_BYTES = 64.kilobytes

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
      token = doc_ref.to_s.strip
      match = token.match(/\ADOC-(\d+)\z/i)
      return match[1].to_i if match

      Integer(token, exception: false)
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

    def detail_payload(design_doc)
      DesignDocs::Serializer.detail(design_doc).merge(
        doc_ref: design_doc.display_id,
        markdown: capped_markdown(design_doc.markdown),
        rendered_markdown: capped_markdown(DesignDocs::AnchorMarkers.strip(design_doc.markdown))
      )
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

    def workflow_scope(scope, context)
      return scope.none unless context.repository

      scope.joins(:design_doc_repositories)
        .where(design_doc_repositories: { repository_id: context.repository.id })
    end

    def capped_markdown(markdown)
      truncated = Mcp::Tools.truncate_text(markdown, MAX_MARKDOWN_BYTES)
      return truncated[:text] unless truncated[:truncated]

      "#{truncated[:text]}\n\n[Design doc truncated after #{MAX_MARKDOWN_BYTES} bytes; omitted #{truncated[:omitted_bytes]} bytes.]"
    end
  end
end
