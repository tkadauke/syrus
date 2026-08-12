# Surfaces the specific failure mode WorkerHostHealthSample resilience exists
# to catch: a worker pod whose InstanceVersion heartbeat is alive (so we know
# the pod itself is up) but whose WorkerHostHealthSample stream has gone dark
# (so neither the heartbeat Thread nor the redundant WorkerHostHealthSampleJob
# path has landed a sample recently). Left unnoticed, this only surfaces
# indirectly days later as WorkflowAdmissionBudget's "absent" telemetry
# fallback blocking real work (see workflow_admission_budget.rb). This job
# makes the gap itself visible via a log line as soon as it happens.
class WorkerHostHealthTelemetryCheckJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  STALE_THRESHOLD = 5.minutes

  def perform
    stale_hostnames.each do |hostname|
      Rails.logger.warn(
        "[WorkerHostHealthTelemetryCheckJob] worker #{hostname} has a live heartbeat but no " \
        "WorkerHostHealthSample in the last #{STALE_THRESHOLD.inspect} — the heartbeat Thread " \
        "may be dead or never started on that pod"
      )
    end
  end

  private

  def stale_hostnames
    live_worker_hostnames - recently_sampled_hostnames
  end

  def live_worker_hostnames
    InstanceVersion.fresh.where(role: "worker").pluck(:hostname)
  end

  def recently_sampled_hostnames
    WorkerHostHealthSample.where("observed_at >= ?", STALE_THRESHOLD.ago)
                           .where("role LIKE ?", "%worker%")
                           .distinct
                           .pluck(:hostname)
  end
end
