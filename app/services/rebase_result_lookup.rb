module RebaseResultLookup
  def result_for(workflow, job)
    stack_entry = Array(workflow.artifact(StackRebasePlan::RESULTS_ARTIFACT)).find do |entry|
      entry["job_id"].to_i == job.id
    end
    stack_entry&.fetch("result", nil) || workflow.artifact("auto_rebase_result")
  end

  def pr_head_sha(pr)
    pr.head&.sha.to_s.presence
  end

  def pr_base_sha(pr)
    pr.base&.sha.to_s.presence
  end
end
