class PollAllMergeStatesJob < ApplicationJob
  queue_as :default

  # Fan-out for the unified rebase + auto-merge loop. Iterates every
  # Job that has a PR — Syrus-authored (pr_number) OR external
  # (external_pr_number, set by the preempted-Job ingest path) when
  # we control the head repo. Each enqueued PollMergeStateJob
  # decides per-PR whether to dispatch AutoMerge, Rebase, or wait.
  def perform
    return if AppSetting.polling_paused?

    Job.joins(:repository)
       .merge(Repository.active)
       .where("pr_number IS NOT NULL OR external_pr_number IS NOT NULL")
       .find_each do |job|
      PollMergeStateJob.perform_later(job.id)
    end
  end
end
