require "json"

module DesignDocs
  module McpToolSupport
    MAX_MARKDOWN_BYTES = 64.kilobytes

    def tool_definitions_for(classes)
      classes.map do |klass|
        {
          name: klass.tool_name,
          description: klass.description_value,
          input_schema: klass.input_schema_value.to_h
        }
      end
    end

    def symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end

    def ok_response(payload)
      MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ])
    end

    def error_response(message)
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{message}" } ], error: true)
    end

    def doc_ref_description
      "Canonical design doc reference. Use either an integer id or DOC-<id>, for example DOC-123."
    end

    def doc_from_ref(ref, scope:)
      id = ref.to_s.strip.sub(/\ADOC-/i, "")
      return nil unless id.match?(/\A\d+\z/)

      scope.find_by(id: id.to_i)
    end

    def capped_markdown(markdown)
      result = Mcp::Tools.truncate_text(markdown.to_s, MAX_MARKDOWN_BYTES)
      return result[:text] unless result[:truncated]

      "#{result[:text]}\n\n[Design doc truncated after #{MAX_MARKDOWN_BYTES} bytes; omitted #{result[:omitted_bytes]} bytes.]"
    end

    def design_doc_summary(design_doc)
      App::DesignDocSerializer.summary(design_doc)
    end

    def design_doc_detail(design_doc)
      App::DesignDocSerializer.detail(design_doc).merge(markdown: capped_markdown(design_doc.markdown))
    end

    def readable_scope(user:, repository: nil)
      scope = DesignDoc.visible_to(user).includes(:owner_user, :repositories, :current_version)
      return scope unless repository

      scope.joins(:design_doc_repositories).where(design_doc_repositories: { repository_id: repository.id })
    end

    def repository_from_id(user, repository_id)
      return nil if repository_id.blank?

      Repository.accessible_to(user).find_by(id: repository_id)
    end

    def current_chat_message_id(server_context)
      server_context[:current_message]&.try(:id)
    end
  end
end
