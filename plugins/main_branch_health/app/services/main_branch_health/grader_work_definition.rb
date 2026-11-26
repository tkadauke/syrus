module MainBranchHealth
  class GraderWorkDefinition < ::Syrus::Host::WorkDefinitionBase
    include Syrus::Host::WorkDefinitionsAgentConcurrencyExempt
    include Syrus::Host::WorkDefinitionsRecordsGraderTargetSelectionInputs

    self.plugin = "main_branch_health"
    self.kind = "main_grader"
    self.workflow_trigger_kind = "main_grader"
    self.runtime_role = "infrastructure"
    self.scope = "repository"

    # Grading main observes a commit that is already on the branch. It changes
    # nothing, and the next landing unit is assembled on top of what it is
    # grading -- so it has no reason to hold the repository key that landing
    # needs. Inheriting the repository lock scope made it a mutex against
    # landing instead: every landed train was followed by a window in which
    # JobBundleDispatcher could not instantiate a bundle at all, and main
    # grades on one production day ran 41, 64, 253, 50 and 46 minutes. With a
    # ~30-minute train, landing spent more time waiting on the grade of the
    # commit it had just produced than it spent landing.
    #
    # Its own namespaced key still serializes main grades against each other,
    # the same shape the repair definition uses for the lock that is genuinely its
    # own.
    def lock_keys_for(job:, member_jobs:, artifacts: {}, **)
      keys = member_jobs.map { |member_job| "job:#{member_job.id}" }
      keys << "main_grader:repository:#{job.repository_id}" if job.repository_id.present?
      keys.uniq
    end

    def grader_fanout_changed_files_base_ref(workflow:, default_base_ref:)
      workflow.artifact("previous_main_sha").to_s.presence
    end

    def grader_fanout_changed_files_log(workflow)
      previous_sha = workflow.artifact("previous_main_sha").to_s.presence
      if previous_sha
        "[grader_fanout] computing affected targets from previous main SHA #{previous_sha.first(7)}"
      else
        "[grader_fanout] no previous main SHA recorded; baseline target health will run every configured grader"
      end
    end

    def grader_fanout_baseline_selection_reason(workflow)
      return nil if workflow.artifact("previous_main_sha").present?

      "baseline main target health has no previous SHA"
    end

    def grader_fanout_reuse_enabled?(workflow)
      grader_fanout_baseline_selection_reason(workflow).blank?
    end
  end
end
