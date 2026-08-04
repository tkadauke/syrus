class PollAllMergeStatesJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  # Fan-out for the unified rebase + auto-merge loop. Iterates every
  # Job that has a PR — Syrus-authored (pr_number) OR external
  # (external_pr_number, set by the preempted-Job ingest path) when
  # we control the head repo. Each enqueued PollMergeStateJob
  # decides per-PR whether to dispatch AutoMerge, Rebase, or wait.
  def perform
    return if AppSetting.polling_paused?

    pollable_jobs.find_each do |job|
      PollMergeStateJob.perform_later(job.id)
    end
  end

  private

  def pollable_jobs
    Job.joins(:repository)
       .merge(Repository.active)
       .where(<<~SQL.squish, closed: "closed", preempted: "preempted")
         (
           jobs.state != :closed
           AND (jobs.pr_number IS NOT NULL OR jobs.external_pr_number IS NOT NULL)
         )
         OR (
           jobs.state = :closed
           AND jobs.closure_reason = :preempted
           AND jobs.external_pr_number IS NOT NULL
         )
       SQL
  end
end
