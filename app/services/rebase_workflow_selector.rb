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
    StackRebasePlan.descendants_for(job).any? || stack_member_with_parent?(job)
  end

  def self.stack_member_with_parent?(job)
    job.parent_job.present? && job.parent_job.open? && job.parent_job.branch_name.present?
  end
  private_class_method :stack_member_with_parent?

  def self.active_for_stack?(job)
    runnable_active_scope(
      Workflow.active.where(trigger_kind: TRIGGER_KINDS, job_id: StackRebasePlan.related_job_ids_for(job))
    ).exists?
  end

  def self.active_in_repository(repository)
    runnable_active_scope(
      Workflow.active
              .where(trigger_kind: TRIGGER_KINDS)
              .joins(:job)
              .where(jobs: { repository_id: repository.id })
    )
  end

  def self.runnable_active_scope(scope)
    scope.where(<<~SQL.squish, "running")
      workflows.state = ?
      OR EXISTS (
        SELECT 1
        FROM steps
        INNER JOIN runs ON runs.step_id = steps.id
        WHERE steps.workflow_id = workflows.id
      )
    SQL
  end
  private_class_method :runnable_active_scope
end
