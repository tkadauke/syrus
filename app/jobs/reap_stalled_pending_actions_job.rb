# Fails chat pending actions whose confirmation stopped without recording an
# outcome. Zombie Runs have ReapStaleRunsJob; a pending action stuck in
# `confirming` had nothing, so its card kept a spinner indefinitely and the
# operator could not dismiss it -- the controller treats such an action as
# neither rejectable nor terminal.
class ReapStalledPendingActionsJob < ApplicationJob
  include SkipIfPending

  queue_as :control_plane
  limits_concurrency to: 1, key: "reap_stalled_pending_actions", duration: 10.minutes, on_conflict: :discard

  def perform
    reaped = ChatPendingAction.stalled_confirming.find_each.count do |action|
      action.fail_stalled_confirmation!
    end
    return if reaped.zero?

    Rails.logger.info("[ReapStalledPendingActionsJob] failed #{reaped} stalled pending action(s)")
  end
end
