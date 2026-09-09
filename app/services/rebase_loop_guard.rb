class RebaseLoopGuard
  extend RebaseResultLookup

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
    return false unless rebase_result_covers_pr_head?(result, pr)
    return true if result["reason"] == AutoRebase::ALREADY_LANDED_REASON

    base_sha = result["base_sha"].presence
    current_base_sha = current_base_sha(job: job, pr: pr, client: client)
    return true if base_sha.blank? || current_base_sha.blank?

    base_sha == current_base_sha
  end

  def self.noop_result?(result)
    result.is_a?(Hash) &&
      result["changed"] == false &&
      [ "rebased", AutoRebase::ALREADY_LANDED_REASON ].include?(result["reason"])
  end
  private_class_method :noop_result?

  def self.rebase_result_covers_pr_head?(result, pr)
    head_sha = pr_head_sha(pr)
    return false if head_sha.blank?

    comparison_sha =
      if result["reason"] == AutoRebase::ALREADY_LANDED_REASON
        result["pre_sha"].presence
      else
        result["post_sha"].presence
      end
    comparison_sha.present? && comparison_sha == head_sha
  end
  private_class_method :rebase_result_covers_pr_head?

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
