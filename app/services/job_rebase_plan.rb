class JobRebasePlan
  def self.for(job, bypass_front_of_queue: true)
    new(job, bypass_front_of_queue: bypass_front_of_queue).to_h
  end

  def initialize(job, bypass_front_of_queue: true)
    @job = job
    @bypass_front_of_queue = bypass_front_of_queue
  end

  def to_h
    {
      "job_id" => @job.id,
      "slug" => @job.slug,
      "state" => @job.state,
      "branch_name" => @job.branch_name,
      "current_base" => @job.mergeability_base_ref.presence || @job.effective_base_branch,
      "target_base" => target_base,
      "pr_number" => @job.pr_number || @job.external_pr_number,
      "commits_behind" => @job.commits_behind_base,
      "checks_state" => @job.pr_checks_state,
      "mergeable_state" => @job.github_mergeable_state || @job.local_mergeable_state,
      "landing_queue_position" => @job.landing_queue_position,
      "landing_queue_entry_position" => @job.landing_queue_entry_position,
      "workflow_trigger_kind" => workflow_trigger_kind,
      "bypass_front_of_queue" => @bypass_front_of_queue,
      "expected_landing_impact" => expected_landing_impact,
      "warnings" => warnings
    }
  end

  private

  def target_base
    RebaseTarget.branch_for(job: @job)
  end

  def workflow_trigger_kind
    RebaseWorkflowSelector.stack_rebase?(@job) ? "stack_rebase" : "rebase"
  end

  def expected_landing_impact
    return "no PR branch is available to rebase" if (@job.pr_number || @job.external_pr_number).blank?
    return "active rebase workflow must finish first" if RebaseWorkflowSelector.active_for_stack?(@job)
    return "successful rebase will retry landing immediately" if @job.approved?
    return "successful rebase will update the PR branch without changing approval state" if @job.open?

    "closed Job will not be rebased"
  end

  def warnings
    [].tap do |items|
      items << "closed_job" if @job.closed? || @job.no_change_needed?
      items << "missing_pr" if (@job.pr_number || @job.external_pr_number).blank?
      items << "missing_branch" if @job.branch_name.blank?
      items << "active_rebase_workflow" if RebaseWorkflowSelector.active_for_stack?(@job)
      items << "not_approved" unless @job.approved?
      items << "failing_or_pending_checks" if @job.pr_checks_state.present? && @job.pr_checks_state != "success"
      items << "dirty_mergeability" if @job.github_mergeable_state.to_s == "dirty" || @job.local_mergeable_state.to_s == "dirty"
      items << "behind_base" if @job.commits_behind_base.to_i.positive?
      items << "not_front_of_queue" if !front_of_queue?
    end
  end

  def front_of_queue?
    position = @job.landing_queue_entry_position || @job.landing_queue_position
    position.blank? || position.to_i <= 1
  end
end
