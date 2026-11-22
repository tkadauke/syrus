module Mail
  class WorkflowToolSet < ChatToolSet
    include Syrus::Plugin::McpToolSet
    def self.available_for?(_repository) = Mail.enabled?
    def self.tool_definitions(context: nil) = super(tier: :deferred)
  end
end
