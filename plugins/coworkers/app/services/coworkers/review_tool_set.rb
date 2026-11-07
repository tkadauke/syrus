class Coworkers::ReviewToolSet
  include Syrus::Plugin::McpToolSet

  TOOL_CLASSES = [ Coworkers::UpdateReviewMemoryTool ].freeze

  def self.available_for?(_repository) = Coworkers.enabled?
  def self.available_for_context?(context) = available_for?(context.repository) && context.role == AgentRole::WORKFLOW_COWORKER_REVIEWER
  def self.tool_definitions(context: nil)
    return [] if context && !available_for_context?(context)
    TOOL_CLASSES.map do |tool|
      { name: tool.tool_name, description: tool.description_value, input_schema: tool.input_schema_value.to_h,
        capability: "review.memory.write", mutation: true, coworker_safe: true }
    end
  end

  def handle(tool_name, params, server_context)
    context = McpToolContext.from_server_context(server_context)
    return Mcp::Tools.not_authorized unless self.class.available_for_context?(context)
    tool = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
    return Mcp::Tools.invalid("unknown coworker review memory tool") unless tool
    tool.call(**(params || {}).symbolize_keys, server_context:)
  end
end
