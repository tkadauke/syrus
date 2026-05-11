class PollAllRebasesJob < ApplicationJob
  queue_as :default

  # Fan-out for the auto-rebase loop. Iterates every Job that has a
  # PR — Syrus-authored (pr_number) OR external (external_pr_number,
  # set by the preempted-Job ingest path). Importantly we DO NOT
  # filter by Job state — rebase is a maintenance task that's
  # independent of Job lifecycle. A preempted (closed) Job whose
  # external PR has gone stale should still get rebased; we own the
  # branch, the human just owns the PR.
  def perform
    return if AppSetting.polling_paused?
    return if ActiveModel::Type::Boolean.new.cast(ENV["SYRUS_UNIFIED_MERGE_POLLER"])

    Job.joins(:repository)
       .merge(Repository.active)
       .where("pr_number IS NOT NULL OR external_pr_number IS NOT NULL")
       .find_each do |job|
      PollRebaseJob.perform_later(job.id)
    end
  end
end
