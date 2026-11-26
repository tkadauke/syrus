module MainBranchHealth
  class RepairWorkDefinition < ::Syrus::Host::WorkDefinitionBase
    include Syrus::Host::WorkDefinitionsAgentConcurrencyExempt
    include Syrus::Host::WorkDefinitionsOpensReviewPullRequest
    include Syrus::Host::WorkDefinitionsManagesOwnJobLifecycle
    include Syrus::Host::WorkDefinitionsResumesFailedSteps
    include Syrus::Host::WorkDefinitionsCheckpointPreemptable

    self.plugin = "main_branch_health"
    self.kind = "main_branch_repair"
    self.workflow_trigger_kind = "main_branch_repair"
    self.runtime_role = "first_class"
    self.scope = "repository"

    def lock_keys_for(job:, member_jobs:, artifacts: {}, **)
      keys = member_jobs.map { |member_job| "job:#{member_job.id}" }
      keys << "main_branch_repair:repository:#{job.repository_id}" if job.repository_id.present?
      if job.repository_id.present? && job.repository&.main_branch_repair_blocks_work?
        keys << "repository:#{job.repository_id}"
      end
      keys.uniq
    end
  end
end
