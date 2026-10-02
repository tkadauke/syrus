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
    self.lock_scope = "none"

    def lock_conflicts_enforced? = true

    def lock_keys_for(job:, member_jobs:, artifacts: {}, **)
      keys = super
      keys << "agent_insight:repository:#{job.repository_id}" if job.repository_id.present?
      keys.uniq
    end
  end
end
