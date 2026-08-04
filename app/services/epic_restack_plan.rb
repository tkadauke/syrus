require "set"

class EpicRestackPlan
  def self.for(epic)
    new(epic).to_h
  end

  def initialize(epic)
    @epic = epic
  end

  def to_h
    {
      "epic_id" => @epic.id,
      "slug" => @epic.slug,
      "strategy" => "dependency_topology",
      "branch_order" => branch_order,
      "skipped_nodes" => skipped_nodes,
      "expected_landing_impact" => expected_landing_impact
    }
  end

  def actions
    branch_order
  end

  private

  def branch_order
    @branch_order ||= ordered_jobs.filter_map do |job|
      next unless rebaseable_job?(job)
      next if blocked_by_skipped_dependency?(job)

      parent = selected_parent(job)
      {
        "job_id" => job.id,
        "slug" => job.slug,
        "branch_name" => job.branch_name,
        "current_base" => job.mergeability_base_ref.presence || job.effective_base_branch,
        "target_base" => parent&.branch_name.presence || job.base_default_branch,
        "target_parent_job_id" => parent&.id,
        "pr_number" => job.pr_number || job.external_pr_number,
        "commits_behind" => job.commits_behind_base,
        "state" => job.state,
        "checks_state" => job.pr_checks_state,
        "mergeable_state" => job.github_mergeable_state || job.local_mergeable_state
      }
    end
  end

  def skipped_nodes
    @skipped_nodes ||= child_jobs.filter_map do |job|
      reason = skipped_reason(job)
      next unless reason

      {
        "job_id" => job.id,
        "slug" => job.slug,
        "state" => job.state,
        "branch_name" => job.branch_name,
        "pr_number" => job.pr_number || job.external_pr_number,
        "reason" => reason
      }
    end
  end

  def expected_landing_impact
    return "no open child PR branches need restacking" if branch_order.empty?

    roots = branch_order.count { |entry| entry["target_parent_job_id"].blank? }
    "updates stack parents to dependency topology and dispatches #{roots} rebase root(s)"
  end

  def skipped_reason(job)
    return "merged" if job.closed? && job.closure_reason.in?(%w[pr_merged external_pr_merged])
    return "closed" if job.closed? || job.no_change_needed?
    return "blocked" if job.blocked_by_epic?
    return "not_open" unless job.open?
    return "missing_branch" if job.branch_name.blank?
    return "missing_pr" if (job.pr_number || job.external_pr_number).blank?
    return "active_rebase_workflow" if RebaseWorkflowSelector.active_for_stack?(job)
    return "fan_in_dependency" if same_epic_open_dependencies(job).size > 1
    return "dependency_not_restacked" if blocked_by_skipped_dependency?(job)

    nil
  end

  def blocked_by_skipped_dependency?(job)
    skipped_dependency_ids.include?(job.id)
  end

  def skipped_dependency_ids
    @skipped_dependency_ids ||= begin
      skipped = Set.new
      child_jobs.each do |job|
        same_epic_open_dependencies(job).each do |dependency|
          skipped << job.id if skipped_reason_without_dependency_check(dependency)
          skipped << job.id if skipped.include?(dependency.id)
        end
      end
      skipped
    end
  end

  def skipped_reason_without_dependency_check(job)
    return "merged" if job.closed? && job.closure_reason.in?(%w[pr_merged external_pr_merged])
    return "closed" if job.closed? || job.no_change_needed?
    return "blocked" if job.blocked_by_epic?
    return "not_open" unless job.open?
    return "missing_branch" if job.branch_name.blank?
    return "missing_pr" if (job.pr_number || job.external_pr_number).blank?
    return "active_rebase_workflow" if RebaseWorkflowSelector.active_for_stack?(job)
    return "fan_in_dependency" if same_epic_open_dependencies(job).size > 1

    nil
  end

  def selected_parent(job)
    dependencies = same_epic_open_dependencies(job)
    return nil if dependencies.empty?

    dependencies.first
  end

  def same_epic_open_dependencies(job)
    job.dependencies.includes(:depends_on_job).filter_map(&:depends_on_job).select do |dependency|
      dependency.epic_id == @epic.id && !dependency.dependency_succeeded?
    end
  end

  def ordered_jobs
    @ordered_jobs ||= begin
      ids = child_jobs.map(&:id).to_set
      indegree = child_jobs.index_with { 0 }
      outgoing = Hash.new { |hash, key| hash[key] = [] }

      child_jobs.each do |job|
        same_epic_dependencies(job).each do |dependency|
          next unless ids.include?(dependency.id)

          outgoing[dependency] << job
          indegree[job] += 1
        end
      end

      ready = indegree.select { |_job, degree| degree.zero? }.keys.sort_by(&:id)
      ordered = []
      until ready.empty?
        job = ready.shift
        ordered << job
        outgoing[job].sort_by(&:id).each do |child|
          indegree[child] -= 1
          ready << child if indegree[child].zero?
        end
        ready.sort_by!(&:id)
      end

      ordered.size == child_jobs.size ? ordered : child_jobs
    end
  end

  def same_epic_dependencies(job)
    job.dependencies.includes(:depends_on_job).filter_map(&:depends_on_job).select do |dependency|
      dependency.epic_id == @epic.id
    end
  end

  def child_jobs
    @child_jobs ||= @epic.work_jobs.includes(:repository, :parent_job, dependencies: :depends_on_job).order(:id).to_a
  end

  def rebaseable_job?(job)
    skipped_reason(job).nil?
  end
end
