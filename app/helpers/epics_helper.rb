module EpicsHelper
  def epic_blocked?(epic)
    epic.dependencies.any? { |dependency| !dependency.depends_on_epic.done? }
  end

  def epic_done_jobs_count(epic)
    epic.jobs.count do |job|
      job.closed? && Epic::MERGED_JOB_CLOSURE_REASONS.include?(job.closure_reason)
    end
  end

  def epic_total_jobs_count(epic)
    epic.jobs.size
  end

  def epic_child_repositories(epic)
    repositories = epic.jobs.map(&:repository).compact
    repositories = [ epic.repository ] if repositories.empty?
    repositories.uniq(&:id).sort_by { |repository| repository.slug.downcase }
  end

  def epic_dependency_edge_count(epic)
    epic.dependencies.size + epic.dependent_links.size
  end

  def epic_lane_title(state)
    state.to_s.humanize.titleize
  end
end
