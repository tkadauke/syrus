class RebaseLoopGuard
  BLOCK_REASON = "waiting for GitHub mergeability after no-op rebase".freeze

  def self.latest_noop_rebase(job)
    Workflow.where(job_id: StackRebasePlan.related_job_ids_for(job))
       .where(trigger_kind: RebaseWorkflowSelector::TRIGGER_KINDS, state: "succeeded")
       .reorder(id: :desc)
       .detect { |workflow| noop_result?(result_for(workflow, job)) }
  end

  def self.waiting_after_noop?(job)
    job.pr_mergeable == false && latest_noop_rebase(job).present?
  end

  def self.noop_rebase_for?(job:, pr:, client: nil)
    workflow = latest_noop_rebase(job)
    return false unless workflow

    result = result_for(workflow, job)
    post_sha = result["post_sha"].presence
    return false if post_sha.blank?
    return false unless post_sha == pr_head_sha(pr)

    base_sha = result["base_sha"].presence
    current_base_sha = current_base_sha(job: job, pr: pr, client: client)
    return true if base_sha.blank? || current_base_sha.blank?

    base_sha == current_base_sha
  end

  def self.noop_result?(result)
    result.is_a?(Hash) && result["changed"] == false && result["reason"] == "rebased"
  end
  private_class_method :noop_result?

  def self.result_for(workflow, job)
    stack_entry = Array(workflow.artifact(StackRebasePlan::RESULTS_ARTIFACT)).find do |entry|
      entry["job_id"].to_i == job.id
    end
    stack_entry&.fetch("result", nil) || workflow.artifact("auto_rebase_result")
  end
  private_class_method :result_for

  def self.pr_head_sha(pr)
    pr.head&.sha.to_s.presence
  end
  private_class_method :pr_head_sha

  def self.pr_base_sha(pr)
    pr.base&.sha.to_s.presence
  end
  private_class_method :pr_base_sha

  def self.pr_base_ref(pr)
    pr.base&.ref.to_s.presence
  end
  private_class_method :pr_base_ref

  def self.current_base_sha(job:, pr:, client:)
    live_base_sha(job: job, pr: pr, client: client) || pr_base_sha(pr)
  rescue StandardError => e
    Rails.logger.warn("[RebaseLoopGuard] live base lookup failed for #{job.slug}: #{e.class}: #{e.message}")
    pr_base_sha(pr)
  end
  private_class_method :current_base_sha

  def self.live_base_sha(job:, pr:, client:)
    return unless client

    branch = pr_base_ref(pr) || job.effective_base_branch
    return if branch.blank?

    client.branch_head_sha(job.effective_pr_repository.slug, branch).to_s.presence
  end
  private_class_method :live_base_sha
end
