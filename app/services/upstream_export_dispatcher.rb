# Story 8/9 (docs/plans/delivery-tracks-and-promotion.md) per-job
# upstream-export entry point: after an existing dev Job is approved
# locally, open/update a PR from that Job's own branch to
# `Repository#upstream_repository`'s (canonical's) configured intake
# branch. Unlike PromotionDispatcher/HotfixSyncDispatcher, this does not
# create a synthetic anchor Job — the branch and its history already exist
# on the Job that was just approved, so Workflows::UpstreamExport dispatches
# directly onto it via WorkUnits::Launcher, the same way RebaseWorkflowSelector
# dispatches Workflows::Rebase onto an existing Job.
#
# Called from Job#dispatch_upstream_export_after_approval via
# UpstreamExportDispatchJob.
class UpstreamExportDispatcher
  def self.call!(job)
    new(job).call!
  end

  def initialize(job)
    @job = job
  end

  def call!
    return unless eligible?

    workflow = WorkUnits::Launcher.instantiate(
      kind: "upstream_export",
      job: @job,
      source_type: "upstream_export_dispatcher"
    )
    WorkUnits::Launcher.start!(workflow)
  end

  private

  def eligible?
    return false unless @job.open?
    return false unless @job.branch_name.present?
    return false unless canonical.present?
    return false unless policy.export_upstream_after_local_approval?(@job)
    return false if already_exported?
    return false if active_export_workflow?

    true
  end

  def canonical
    @job.repository.upstream_repository
  end

  def policy
    @policy ||= DeliveryPolicy.for(repository: @job.repository, job: @job)
  end

  def already_exported?
    @job.pr_links.find_by(role: JobPrLink::ROLE_UPSTREAM_EXPORT)&.pr_number.present?
  end

  def active_export_workflow?
    @job.workflows.where(trigger_kind: "upstream_export", state: %w[queued running]).exists?
  end
end
