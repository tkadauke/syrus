require "mcp"

module MainBranchHealth
  # Lets implementation-style workflow agents report a suspicion that main was
  # already broken. Reviewers only see a diff and cannot tell real main-branch
  # regressions from transient infrastructure failures, so granting the tool to
  # them would produce false quorum signals.
  class McpToolSet
    include Syrus::Plugin::McpToolSet

    TOOL_CLASSES = [ Tools::ReportMainConcernTool ].freeze
    REPORTING_ROLES = [
      AgentRole::WORKFLOW_IMPLEMENT,
      "workflow:summary_test_plan",
      "workflow:rebase_conflict",
      Syrus::Host::AgentRoles::WORKFLOW_MANUAL
    ].freeze

    def self.available_for?(_repository) = true

    def self.available_for_context?(context)
      context.run? && REPORTING_ROLES.include?(context.role)
    end

    def self.tool_definitions(context: nil)
      return [] if context && !available_for_context?(context)

      TOOL_CLASSES.map do |klass|
        {
          name: klass.tool_name,
          description: klass.description_value,
          input_schema: klass.input_schema_value.to_h,
          capability_descriptor: PermissionProvider.capability_descriptor(PermissionProvider::OPERATIONS.fetch(klass.tool_name))
        }
      end
    end

    def handle(tool_name, params, server_context)
      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return ::Mcp::Tools.invalid("Unknown main-branch health tool: #{tool_name.inspect}") unless klass

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      Rails.logger.error("[MainBranchHealth::McpToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
