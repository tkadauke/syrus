class LandingQueueRecheck
  Result = Data.define(:job, :pr_refreshed, :checks_refreshed, :commits_behind_refreshed, :queue_entry, :warnings) do
    def refreshed_state
      job.reload
      {
        job_id: job.id,
        slug: job.slug,
        state: job.state,
        pr_number: job.pr_number || job.external_pr_number,
        pr_checks_state: job.pr_checks_state,
        pr_checks_sha: job.pr_checks_sha,
        github_mergeable: job.github_mergeable,
        github_mergeable_state: job.github_mergeable_state,
        mergeability_head_sha: job.mergeability_head_sha,
        mergeability_base_sha: job.mergeability_base_sha,
        mergeability_base_ref: job.mergeability_base_ref,
        commits_behind_base: job.commits_behind_base,
        landing_queue_blocked_reason: job.landing_queue_blocked_reason,
        landing_queue_position: job.landing_queue_position,
        landing_queue_entry_position: job.landing_queue_entry_position,
        landing_queue_waiting_job_ids: job.landing_queue_waiting_job_ids,
        landing_queue_blocker_job_ids: job.landing_queue_blocker_job_ids,
        landing_queue_dependency_edges: job.landing_queue_dependency_edges,
        refreshed: {
          pr: pr_refreshed,
          checks: checks_refreshed,
          commits_behind: commits_behind_refreshed
        },
        warnings: warnings
      }
    end
  end

  def self.call(job)
    new(job).call
  end

  def initialize(job)
    @job = job
    @warnings = []
  end

  def call
    pr = refresh_pr_state
    checks_refreshed = refresh_checks(pr)
    commits_behind_refreshed = refresh_commits_behind(pr)
    entry = LandingQueueProcessor.refresh_snapshot!(queue_scope).find { |candidate| candidate.job_id == @job.id }
    LandingQueueProcessorJob.perform_later

    Result.new(
      job: @job,
      pr_refreshed: pr.present?,
      checks_refreshed: checks_refreshed,
      commits_behind_refreshed: commits_behind_refreshed,
      queue_entry: entry,
      warnings: @warnings
    )
  end

  private

  def refresh_pr_state
    pr_number = @job.pr_number || @job.external_pr_number
    return warn("Job has no tracked PR.") if pr_number.blank?

    pr = client.pull_request(pr_repository.slug, pr_number, bypass_cache: true)
    MergeabilityRecorder.record_github!(job: @job, pr: pr)
    pr
  rescue Octokit::Forbidden, Octokit::Unauthorized => e
    raise e
  rescue StandardError => e
    warn("PR refresh failed: #{e.class}: #{e.message}")
  end

  def refresh_checks(pr)
    head_sha = MergeabilityRecorder.head_sha(pr).presence || @job.mergeability_head_sha.presence || @job.pr_checks_sha.presence
    return false if head_sha.blank?

    detail = client.check_runs_detail_for(pr_repository.slug, head_sha)
    state = if detail[:any_failed?] then "failing"
            elsif detail[:pending?] then "pending"
            elsif detail[:all_passed?] then "passing"
            else "unknown"
            end
    @job.update_columns(pr_checks_sha: head_sha, pr_checks_state: state, pr_checks_checked_at: Time.current)
    true
  rescue Octokit::Forbidden, Octokit::Unauthorized => e
    raise e
  rescue StandardError => e
    warn("check-run refresh failed: #{e.class}: #{e.message}")
    false
  end

  def refresh_commits_behind(pr)
    head_sha = MergeabilityRecorder.head_sha(pr).presence || @job.mergeability_head_sha.presence
    base_sha = MergeabilityRecorder.base_sha(pr).presence || @job.mergeability_base_sha.presence
    return false if head_sha.blank? || base_sha.blank?

    bare_clone = RepositoryBareClone.new(pr_repository)
    bare_clone.sync!(user: @job.user)
    distance = bare_clone.commits_behind(head_sha: head_sha, base_sha: base_sha)
    @job.update_column(:commits_behind_base, distance)
    true
  rescue StandardError => e
    warn("commits-behind refresh failed: #{e.class}: #{e.message}")
    false
  end

  def queue_scope
    Job.where(repository_id: @job.repository_id, state: %w[approved landing])
  end

  def client
    @client ||= GithubClient.for(repository: pr_repository, user: @job.user)
  end

  def pr_repository
    @pr_repository ||= @job.effective_pr_repository
  end

  def warn(message)
    @warnings << message
    nil
  end
end
