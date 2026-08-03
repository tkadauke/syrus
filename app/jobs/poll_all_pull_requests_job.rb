class PollAllPullRequestsJob < ApplicationJob
  include SkipIfPending

  queue_as :default

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
    Job.joins(:repository)
       .merge(Repository.active)
       .open_threads.where.not(pr_number: nil)
       .find_each do |job|
      PollPullRequestJob.perform_later(job.id)
    end

    Job.joins(:repository)
       .merge(Repository.active)
       .open_threads.where.not(external_pr_number: nil)
       .where("jobs.pr_number IS NULL OR jobs.kind = ?", "external_pr")
       .find_each do |job|
      PollExternalPrJob.perform_later(job.id)
    end

    # Fan-out to fork review PR polling for jobs in fork review mode that have
    # not yet had their upstream PR created. Once pr_number is set the job
    # transitions to normal polling via PollPullRequestJob above.
    Job.joins(:repository)
       .merge(Repository.active)
       .open_threads.where(pr_number: nil).where.not(fork_review_pr_number: nil)
       .find_each do |job|
      PollForkReviewPrJob.perform_later(job.id)
    end
  end
end
