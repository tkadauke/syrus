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
    active_for_jobs?([ job ])
  end

  def self.active_for_jobs?(jobs)
    job_ids = related_job_ids_for(jobs)
    return false if job_ids.empty?

    WorkUnits::Ownership.active_unit_members_for_job_ids(job_ids, kinds: TRIGGER_KINDS).exists? ||
      active_legacy_workflows_for_job_ids(job_ids).exists?
  end

  def self.active_for_jobs(jobs)
    job_ids = related_job_ids_for(jobs)
    return Workflow.none if job_ids.empty?

    active_workflows_for_job_ids(job_ids)
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
    legacy_ids = runnable_active_scope(
      Workflow.active.where(trigger_kind: TRIGGER_KINDS).joins(:job).where(jobs: { repository_id: repository.id })
    ).pluck(:id)
    unit_ids = WorkUnit
      .where(state: WorkUnits::Ownership::ACTIVE_STATES, kind: TRIGGER_KINDS, repository_id: repository.id)
      .where.not(workflow_id: nil)
      .pluck(:workflow_id)

    Workflow.where(id: (legacy_ids + unit_ids).uniq)
  end

  def self.active_workflows_for_job_ids(job_ids)
    legacy_ids = active_legacy_workflows_for_job_ids(job_ids).pluck(:id)
    unit_ids = WorkUnits::Ownership
      .active_unit_members_for_job_ids(job_ids, kinds: TRIGGER_KINDS)
      .joins(:work_unit)
      .where.not(work_units: { workflow_id: nil })
      .distinct
      .pluck("work_units.workflow_id")

    Workflow.where(id: (legacy_ids + unit_ids).uniq)
  end
  private_class_method :active_workflows_for_job_ids

  def self.active_legacy_workflows_for_job_ids(job_ids)
    runnable_active_scope(Workflow.active.where(trigger_kind: TRIGGER_KINDS, job_id: job_ids))
  end
  private_class_method :active_legacy_workflows_for_job_ids

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
