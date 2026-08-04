class StackRebasePlan
  STACK_ARTIFACT = "stack_rebase_jobs".freeze
  RESULTS_ARTIFACT = "stack_rebase_results".freeze
  AGENT_PENDING_ARTIFACT = "stack_rebase_agent_pending".freeze
  AGENT_PRE_SHAS_ARTIFACT = "stack_rebase_agent_pre_shas".freeze
  AGENT_PUSHES_ARTIFACT = "stack_rebase_agent_pushes".freeze

  def self.descendants_for(job)
    new(job).descendants
  end

  def self.ordered_jobs_for(job)
    new(job).ordered_jobs
  end

  def self.related_job_ids_for(job)
    root = job
    root = root.parent_job while root.parent_job.present?
    new(root).ordered_jobs.map(&:id)
  end

  def self.base_branch_for(job, base_overrides)
    base_overrides[job.id].presence ||
      job.parent_job&.branch_name.presence ||
      job.effective_base_branch
  end

  def self.artifacts_for(job:, artifacts: nil, pr: nil, base_branch: nil)
    jobs = ordered_jobs_for(job)
    base_overrides = {}
    first_base = base_branch.presence || pr&.base&.ref.to_s.presence
    base_overrides[job.id] = first_base if first_base.present?

    merged = RebaseTarget.artifacts(artifacts: artifacts, pr: pr, base_branch: base_branch, branch_name: job.branch_name) || {}
    merged[STACK_ARTIFACT] = jobs.map do |stack_job|
      {
        "job_id" => stack_job.id,
        "pr_number" => stack_job.pr_number || stack_job.external_pr_number,
        "branch_name" => stack_job.branch_name,
        "base_branch" => base_branch_for(stack_job, base_overrides),
        "parent_job_id" => stack_job.parent_job_id
      }
    end
    merged
  end

  def initialize(job)
    @job = job
  end

  def descendants
    @descendants ||= walk_children(@job)
  end

  def ordered_jobs
    [ @job, *descendants ]
  end

  private

  def walk_children(parent)
    parent.stack_children.order(:id).flat_map do |child|
      next [] unless rebaseable_child?(child)

      [ child, *walk_children(child) ]
    end
  end

  def rebaseable_child?(child)
    child.open? &&
      child.branch_name.present? &&
      (child.pr_number.present? || child.external_pr_number.present?)
  end
end
