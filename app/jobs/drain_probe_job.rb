# An operator probe for graceful restarts. It holds a worker thread for the
# given number of seconds and does nothing else, so enqueueing a few on the
# `runs` queue before a deploy shows directly whether a restarted worker
# drained them (SolidQueue records each one finished) or killed them (it
# lands in the failed executions instead). Bounded so a typo cannot pin a
# run slot for a day.
class DrainProbeJob < ApplicationJob
  queue_as :runs

  MAX_SECONDS = 2.hours.to_i

  def perform(seconds)
    duration = seconds.to_i.clamp(0, MAX_SECONDS)
    Rails.logger.info("[DrainProbeJob] holding a worker thread for #{duration}s on #{SyrusVersion.hostname}")
    sleep(duration)
  end
end
