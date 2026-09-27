module OperatorBriefing
  class DiveWorkDefinition < ::WorkDefinitions::Base
    self.plugin = "operator_briefing"
    self.kind = "briefing_dive"
    self.workflow_trigger_kind = "briefing_dive"
    self.runtime_role = "child"
    self.scope = "job"
  end
end
