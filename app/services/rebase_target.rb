class RebaseTarget
  BRANCH_ARTIFACT = "rebase_branch"
  BASE_BRANCH_ARTIFACT = "rebase_base_branch"
  BASE_SHA_ARTIFACT = "rebase_base_sha"

  def self.branch_for(job:, workflow: nil)
    workflow&.artifact(BASE_BRANCH_ARTIFACT).presence ||
      open_parent_branch(job).presence ||
      job.effective_base_branch
  end

  def self.source_branch_for(job:, workflow: nil)
    workflow&.artifact(BRANCH_ARTIFACT).presence ||
      job.branch_name.presence
  end

  def self.open_parent_branch(job)
    parent = job.parent_job
    return unless parent&.repository_id == job.repository_id
    return unless parent&.open? && parent.branch_name.present?
    parent.branch_name
  end
  private_class_method :open_parent_branch

  def self.artifacts(artifacts: nil, pr: nil, base_branch: nil, branch_name: nil)
    merged = (artifacts || {}).dup
    branch = base_branch.presence || pr&.base&.ref.to_s.presence
    sha = pr&.base&.sha.to_s.presence
    source_branch = branch_name.presence || pr_head_ref(pr)

    merged[BRANCH_ARTIFACT] = source_branch if source_branch.present?
    merged[BASE_BRANCH_ARTIFACT] = branch if branch.present?
    merged[BASE_SHA_ARTIFACT] = sha if sha.present?
    merged.presence
  end

  def self.pr_head_ref(pr)
    return unless pr&.respond_to?(:head)

    pr.head&.ref.to_s.presence
  end
  private_class_method :pr_head_ref
end
