require "mcp"

module DesignDocs
  class WorkflowToolSet
    extend McpToolSupport

    TOOL_CLASSES = [
      ListDesignDocsTool,
      ReadDesignDocTool
    ].freeze

    def self.available_for_context?(context)
      context.repository.present? && context.user.present?
    end

    def self.tool_definitions(context: nil)
      tool_definitions_for(TOOL_CLASSES)
    end

    def handle(tool_name, params, server_context)
      context = McpToolContext.from_server_context(server_context)
      return self.class.error_response("No workflow run context available.") unless context.run?
      return self.class.error_response("No repository available in this workflow context.") unless context.repository

      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return self.class.error_response("Unknown design docs tool: #{tool_name.inspect}") unless klass

      klass.call(user: context.user, repository: context.repository, **self.class.symbolize(params))
    rescue StandardError => e
      Rails.logger.error("[DesignDocs::WorkflowToolSet] #{e.class}: #{e.message}")
      self.class.error_response("#{e.class}: #{e.message}")
    end
  end
end
