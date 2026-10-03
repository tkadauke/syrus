module OperatorBriefing
  class WorkDefinition < ::WorkDefinitions::Base
    self.plugin = "operator_briefing"
    self.kind = "briefing_generate"
    self.workflow_trigger_kind = "briefing_generate"
    self.runtime_role = "infrastructure"
    self.scope = "repository"
    self.lock_scope = "none"

    def lock_conflicts_enforced? = true

    def lock_keys_for(job:, member_jobs:, artifacts: {}, **)
      keys = super
      if job.repository_id.present? && job.user_id.present?
        keys << "operator_briefing:repository:#{job.repository_id}:user:#{job.user_id}"
      end
      keys.uniq
    end
  end
end
