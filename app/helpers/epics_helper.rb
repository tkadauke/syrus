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

  def epic_state_transition_options(epic)
    transitions = []
    transitions << [ "Ready", "ready" ] if epic.backlog? && epic.may_auto_ready?
    transitions << [ "Start", "in_progress" ] if epic.ready? && epic.may_start?
    transitions << [ "Move back to ready", "ready" ] if epic.in_progress? && epic.may_unstart?
    transitions << [ "Mark done", "done" ] if epic.in_progress? && epic.may_auto_complete?
    transitions << [ "Archive", "archived" ] if epic.may_archive?
    transitions
  end
end
