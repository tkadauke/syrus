class Coworkers::ReviewToolSet
  include Syrus::Plugin::McpToolSet

  # Roles allowed to call the verdict tool; the memory tool is reviewer-only.
  SUBMIT_ROLES = [ AgentRole::WORKFLOW_COWORKER_REVIEWER, AgentRole::WORKFLOW_MANUAL ].freeze
  REVIEWER_ROLES = [ AgentRole::WORKFLOW_COWORKER_REVIEWER ].freeze
  TOOLS = [
    { tool: Coworkers::UpdateReviewMemoryTool, capability: "review.memory.write", roles: REVIEWER_ROLES },
    { tool: Coworkers::SubmitReviewTool, capability: "review.verdict.submit", roles: SUBMIT_ROLES }
  ].freeze

  def self.available_for?(_repository) = Coworkers.enabled?
  def self.available_for_context?(context) = available_for?(context.repository) && SUBMIT_ROLES.include?(context.role)
  def self.tool_definitions(context: nil)
    return [] if context && !available_for_context?(context)
    TOOLS.select { |entry| context.nil? || entry[:roles].include?(context.role) }.map do |entry|
      tool = entry[:tool]
      { name: tool.tool_name, description: tool.description_value, input_schema: tool.input_schema_value.to_h,
        capability: entry[:capability], mutation: true, coworker_safe: true }
    end
  end

  def handle(tool_name, params, server_context)
    context = McpToolContext.from_server_context(server_context)
    return Mcp::Tools.not_authorized unless self.class.available_for_context?(context)
    entry = TOOLS.find { |candidate| candidate[:tool].tool_name == tool_name.to_s }
    return Mcp::Tools.invalid("unknown coworker review tool") unless entry
    return Mcp::Tools.not_authorized unless entry[:roles].include?(context.role)
    entry[:tool].call(**(params || {}).symbolize_keys, server_context:)
  end
end
