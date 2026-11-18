module ConnectedAccounts
  module Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      RefreshSchedulerJob.perform_later
      HealthProbeJob.perform_later
      PendingFlow.where("expires_at <= ?", Time.current).delete_all
      nil
    end
  end
end
