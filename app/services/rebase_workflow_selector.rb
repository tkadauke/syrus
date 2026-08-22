class RebaseWorkflowSelector
  TRIGGER_KINDS = %w[ rebase stack_rebase ].freeze

  def self.instantiate(job:, artifacts: nil, agent_provider: nil, pr: nil, base_branch: nil)
    if stack_rebase?(job)
      WorkUnits::Launcher.instantiate(
        kind: "stack_rebase",
        job: job,
        artifacts: artifacts,
        agent_provider: agent_provider,
        pr: pr,
        base_branch: base_branch
      )
    else
      WorkUnits::Launcher.instantiate(
        kind: "rebase",
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
    active_for_jobs([ job ]).exists?
  end

  def self.active_for_jobs(jobs)
    job_ids = related_job_ids_for(jobs)
    return Workflow.none if job_ids.empty?

    runnable_active_scope(
      Workflow.active.where(trigger_kind: TRIGGER_KINDS, job_id: job_ids)
    )
  end

  def self.active_merge_train_for_stack?(job)
    active_merge_trains_for_jobs([ job ]).exists?
  end

  def self.active_merge_trains_for_jobs(jobs)
    job_ids = related_job_ids_for(jobs)
    return MergeTrain.none if job_ids.empty?

    MergeTrain.active.joins(:members).where(merge_train_members: { job_id: job_ids }).distinct
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

  def self.related_job_ids_for(jobs)
    Array(jobs).compact.flat_map { |job| StackRebasePlan.related_job_ids_for(job) }.uniq
  end
  private_class_method :related_job_ids_for
end
