module PersonalCalendar
  class WorkflowToolSet < ChatToolSet
    include Syrus::Plugin::McpToolSet
    def self.available_for?(_repository) = PersonalCalendar.enabled?
    def self.tool_definitions(context: nil) = super(tier: :deferred)
  end
end
