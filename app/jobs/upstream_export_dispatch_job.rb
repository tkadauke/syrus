# Background hand-off for Job#dispatch_upstream_export_after_approval —
# keeps the DeliveryPolicy read (git show against the bare clone) and the
# WorkUnits::Launcher dispatch out of the approval's after_update_commit
# callback, mirroring PollPullRequestJob.perform_later in
# Job#poll_pr_checks_after_approval.
class UpstreamExportDispatchJob < ApplicationJob
  queue_as :control_plane

  def perform(job_id)
    job = Job.find_by(id: job_id)
    return unless job

    UpstreamExportDispatcher.call!(job)
  end
end
