module SyrusMail
  class WorkflowToolSet < ChatToolSet
    include Syrus::Host::McpToolSet
    def self.available_for?(_repository) = SyrusMail.enabled?
    def self.tool_definitions(context: nil) = super(tier: :deferred)
  end
end
