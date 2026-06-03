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

  def self.noop_rebase_for?(job:, pr:)
    workflow = latest_noop_rebase(job)
    return false unless workflow

    result = result_for(workflow, job)
    post_sha = result["post_sha"].presence
    return false if post_sha.blank?
    return false unless post_sha == pr_head_sha(pr)

    base_sha = result["base_sha"].presence
    current_base_sha = pr_base_sha(pr)
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
end
