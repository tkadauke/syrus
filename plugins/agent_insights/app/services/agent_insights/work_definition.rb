module AgentInsights
  # WorkUnit policy for the repository-scoped insight sweep. Declared here
  # rather than in core's built-ins so the definition disappears together
  # with the plugin's trigger kind when the plugin is disabled.
  class WorkDefinition < ::WorkDefinitions::Base
    self.plugin = "agent_insights"
    self.kind = "agent_insight"
    self.workflow_trigger_kind = "agent_insight"
    self.runtime_role = "infrastructure"
    self.scope = "repository"
  end
end
