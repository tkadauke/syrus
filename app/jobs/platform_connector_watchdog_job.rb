# A configured/enabled platform connector (Discord::GatewayConnectionJob,
# core PlatformPollingJob subclasses) is normally self-healing: its base
# class re-enqueues itself in an `ensure` block after every poll/Gateway
# cycle. That re-enqueue never runs when the SolidQueue process running it is
# pruned or killed mid-cycle (SolidQueue::Processes::ProcessPrunedError,
# worker OOMKill, a deploy's SIGKILL) -- the job just vanishes, leaving the
# connector configured-but-deaf with nothing in the queue and no error
# anywhere. This job is the independent watchdog: on a short interval it
# re-primes every configured connector (core + plugin) exactly the way boot
# and the admin restart endpoint do, relying on
# PlatformPollingJob.start_one_with_status's own "already running" dedup
# check so a healthy connector is never double-started. Only the connectors
# that were actually missing and got re-enqueued are logged, so a healthy
# fleet produces no log noise.
class PlatformConnectorWatchdogJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  def perform
    (PlatformPollingJob.start_all_with_status! + PlatformDelivery::Registry.start_connectors_with_status!).each do |connector|
      next unless connector[:status] == :started

      Rails.logger.warn(
        "[PlatformConnectorWatchdogJob] #{connector[:name]} was configured but not running -- re-enqueued. " \
        "This usually means its previous connector job was pruned or killed before it could re-enqueue itself."
      )
    end
  rescue StandardError => e
    Rails.logger.warn("[PlatformConnectorWatchdogJob] tick failed: #{e.class}: #{e.message}")
  end
end
