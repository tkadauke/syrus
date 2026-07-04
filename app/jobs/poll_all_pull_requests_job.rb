class PollAllPullRequestsJob < ApplicationJob
  include SkipIfPending

  queue_as :default

  # Fan-out for the PR feedback loop — fires each open thread that has a
  # PR through PollPullRequestJob, which does the actual comment fetching
  # and follow-up Run dispatch.
  #
  # Also fans out to PollExternalPrJob for open Jobs whose issue was
  # preempted by a human-authored PR (external_pr_number set, no pr_number)
  # so the Job closes when that external PR is merged.
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
       .open_threads.where(pr_number: nil).where.not(external_pr_number: nil)
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
