module OperatorBriefing
  class WorkDefinition < ::WorkDefinitions::Base
    self.plugin = "operator_briefing"
    self.kind = "briefing_generate"
    self.workflow_trigger_kind = "briefing_generate"
    self.runtime_role = "infrastructure"
    self.scope = "repository"
  end
end
