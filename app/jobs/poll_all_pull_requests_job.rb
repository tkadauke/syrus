class PollAllPullRequestsJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  # Fan-out for the PR feedback loop — fires each open thread that has a
  # PR through PollPullRequestJob, which does the actual comment fetching
  # and follow-up Run dispatch.
  #
  # Also fans out to PollExternalPrJob for:
  #   - Open Jobs whose issue was preempted by a human-authored PR
  #     (external_pr_number set, no pr_number)
  #   - Open external_pr kind Jobs — including those that also have a
  #     pr_number once the auto-merge workflow creates one
  # so the Job closes when the external PR is merged or closed.
  def perform
    return if AppSetting.polling_paused?
    GithubPollingBudget.take_pollable_jobs(
      Job.joins(:repository)
         .merge(Repository.active)
         .open_threads.where.not(pr_number: nil),
      kind: :pr_feedback,
      limit: GithubPollingBudget::PR_FEEDBACK_LIMIT
    ).each do |job|
      next if job.repository.github_api_rate_limited_for?(user: job.user)

      PollPullRequestJob.perform_later(job.id)
    end

    GithubPollingBudget.take_pollable_jobs(
      Job.joins(:repository)
         .merge(Repository.active)
         .open_threads.where.not(external_pr_number: nil)
         .where("jobs.pr_number IS NULL OR jobs.kind = ?", "external_pr"),
      kind: :external_pr,
      limit: GithubPollingBudget::EXTERNAL_PR_LIMIT
    ).each do |job|
      next if job.repository.github_api_rate_limited_for?(user: job.user)

      PollExternalPrJob.perform_later(job.id)
    end

    # Fan-out to fork review PR polling for jobs in fork review mode that have
    # not yet had their upstream PR created. Once pr_number is set the job
    # transitions to normal polling via PollPullRequestJob above.
    GithubPollingBudget.take_pollable_jobs(
      Job.joins(:repository)
         .merge(Repository.active)
         .open_threads.where(pr_number: nil).where.not(fork_review_pr_number: nil),
      kind: :fork_review,
      limit: GithubPollingBudget::FORK_REVIEW_LIMIT
    ).each do |job|
      next if job.repository.github_api_rate_limited_for?(user: job.user)

      PollForkReviewPrJob.perform_later(job.id)
    end
  end
end
