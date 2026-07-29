class InsightScheduler
  # Enqueues an agent_insight Job for the given repository if no insight job is
  # currently queued or running. Returns the newly created Job, or nil if skipped.
  def self.enqueue_if_idle!(repository)
    return if repository.jobs.where(kind: "agent_insight").where.not(state: "closed").exists?

    user = repository.user
    return unless user

    Job.transaction do
      j = user.jobs.create!(
        repository: repository,
        kind: "agent_insight",
        issue_number: nil,
        issue_title: "Insight analysis: #{repository.slug}",
        owner_user: user
      )
      workflow = Workflows::AgentInsight.instantiate(job: j)
      StepDispatcher.start_workflow(workflow)
      j
    end
  end

  # Returns the count of closed non-insight jobs created after since_at.
  # If since_at is nil, counts all closed non-insight jobs for the repository.
  def self.coding_jobs_since(repository, since_at)
    scope = repository.jobs.where.not(kind: "agent_insight").where(state: "closed")
    scope = scope.where("finished_at > ?", since_at) if since_at
    scope.count
  end

  # Returns the created_at of the most recent agent_insight job for the repository,
  # or nil if none exists.
  def self.last_insight_created_at(repository)
    repository.jobs.where(kind: "agent_insight").order(created_at: :desc).pick(:created_at)
  end
end
