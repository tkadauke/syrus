require "mcp"

module DesignDocs
  class ListDesignDocsTool < MCP::Tool
    extend ToolSupport

    tool_name "list_design_docs"

    description "List readable Design Docs as DOC-<id> references. Chat agents see docs visible to the chat user; workflow agents get read-only docs linked to the run repository."

    input_schema(
      properties: {
        repository_id: { type: "integer", description: "Optional repository id to filter readable design docs; chat contexts may only use attached or accessible repositories, and workflow contexts are fixed to the run repository." },
        query: { type: "string", description: "Optional case-insensitive title or Markdown search text." },
        limit: { type: "integer", description: "Maximum number of docs to return, default 20, max 50." }
      }
    )

    class << self
      def call(server_context:, repository_id: nil, query: nil, limit: 20)
        context = context_from(server_context)
        scope = visible_scope(context).includes(:current_version, :repositories).newest_first

        if repository_id.present?
          repository = scoped_repository(context, repository_id)
          return invalid("repository not found in this agent context: #{repository_id}") unless repository

          scope = scope.joins(:design_doc_repositories).where(design_doc_repositories: { repository_id: repository.id })
        end

        if query.present?
          pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s)}%"
          scope = scope.where("design_docs.title LIKE :pattern OR design_docs.markdown LIKE :pattern", pattern: pattern)
        end

        capped_limit = limit.to_i.clamp(1, 50)
        success(
          design_docs: scope.limit(capped_limit).map { |design_doc| list_payload(design_doc) },
          read_only: context.run?,
          reference_format: "Use DOC-<id>, for example DOC-123, with read_design_doc."
        )
      rescue StandardError => e
        Rails.logger.error("[DesignDocs::ListDesignDocsTool] #{e.class}: #{e.message}")
        tool_error("Could not list design docs: #{e.message}")
      end
    end
  end
end
