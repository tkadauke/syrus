class RebaseWorkflowSelector
  TRIGGER_KINDS = %w[ rebase stack_rebase ].freeze

  def self.instantiate(job:, artifacts: nil, agent_provider: nil, pr: nil, base_branch: nil)
    if stack_rebase?(job)
      Workflows::StackRebase.instantiate(
        job: job,
        artifacts: artifacts,
        agent_provider: agent_provider,
        pr: pr,
        base_branch: base_branch
      )
    else
      Workflows::Rebase.instantiate(
        job: job,
        artifacts: artifacts,
        agent_provider: agent_provider,
        pr: pr,
        base_branch: base_branch
      )
    end
  end

  def self.stack_rebase?(job)
    StackRebasePlan.descendants_for(job).any?
  end

  def self.active_for_stack?(job)
    Workflow.active
            .where(trigger_kind: TRIGGER_KINDS, job_id: StackRebasePlan.related_job_ids_for(job))
            .exists?
  end

  def self.active_in_repository(repository)
    Workflow.active
            .where(trigger_kind: TRIGGER_KINDS)
            .joins(:job)
            .where(jobs: { repository_id: repository.id })
  end
end
