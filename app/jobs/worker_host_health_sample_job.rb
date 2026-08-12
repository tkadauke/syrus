# Independent, redundant path to WorkerHostHealthSample so telemetry does not
# rely solely on InstanceVersionSupervisor's per-process heartbeat Thread
# surviving (app/services/instance_version_supervisor.rb). This job runs on
# Solid Queue's normal job-execution threads, which are separate from that
# heartbeat Thread — so on a pod where the heartbeat Thread died or never
# started, this recurring job still lands fresh samples.
#
# Self-heals the InstanceVersion row too: if registration itself never
# happened (e.g. the supervisor hit a lock-wait timeout at boot), this job
# creates the minimal row it needs rather than silently skipping forever.
class WorkerHostHealthSampleJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    return unless SyrusVersion.role == "worker"

    instance = current_worker_instance
    return unless instance

    WorkerHostHealthSampler.record!(instance: instance)
  rescue StandardError => e
    Rails.logger.warn("[WorkerHostHealthSampleJob] sample failed: #{e.class}: #{e.message}")
  end

  private

  def current_worker_instance
    InstanceVersion.find_or_create_by!(hostname: SyrusVersion.hostname, role: "worker") do |iv|
      iv.version = SyrusVersion.current
      iv.started_at = Time.current
      iv.last_heartbeat_at = Time.current
    end
  rescue StandardError => e
    Rails.logger.warn("[WorkerHostHealthSampleJob] instance lookup failed: #{e.class}: #{e.message}")
    nil
  end
end
