# Recurring sweep for Jobs stuck in triaging/classifier_pending.
#
# ClassifyIssueJob's SolidQueue retries handle most cases, but a few
# escape routes still leave a Job stuck without a pending SQ entry:
#
#   - PollRepositoryJob raises before reaching perform_later (network,
#     GH client, etc.). The Job is committed but the classify enqueue
#     never happens.
#   - SolidQueue's failed_execution retains permanently failed jobs;
#     after retries are exhausted on a transient codex outage, the
#     Job stays classifier_pending with no future attempts scheduled.
#   - Schema or code changes (e.g., agent_provider becomes configured
#     later) leave previously-skipped Jobs orphaned.
#
# This sweep enqueues a fresh ClassifyIssueJob for any Job that's
# been stuck longer than STUCK_THRESHOLD. ClassifyIssueJob's
# concurrency lock keeps duplicate runs from racing.
class ReapClassifierPendingJob < ApplicationJob
  queue_as :low_priority_maintenance

  # 10 minutes balances "give a fresh classify enough time to
  # actually complete" against "don't leave the operator staring at
  # a stuck Job for too long". The classifier itself has a 60s
  # default timeout, and SolidQueue retries should resolve transient
  # failures within a few minutes. Anything past 10 is genuinely
  # stuck or post-SIGKILL.
  STUCK_THRESHOLD = 10.minutes

  def perform
    cutoff = STUCK_THRESHOLD.ago
    stuck = Job.where(state: "triaging", triaging_reason: "classifier_pending")
               .where("created_at < ?", cutoff)

    stuck.find_each do |job|
      Rails.logger.info("[ReapClassifierPendingJob] re-enqueuing classify for #{job.slug} " \
                        "(issue ##{job.issue_number} @ #{job.repository.slug}, " \
                        "stuck since #{job.created_at})")
      ClassifyIssueJob.perform_later(job.id)
    end
  end
end
