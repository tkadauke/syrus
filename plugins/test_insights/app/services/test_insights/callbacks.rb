module TestInsights
  # Retention runs on the plugin's own tick rather than the host's
  # config/recurring.yml, so disabling/removing the plugin removes the
  # schedule with it (same pattern as ScheduledTasks::Callbacks and
  # VideoWalkthroughs::Callbacks).
  module Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      TestInsightsPruneJob.perform_later
      nil
    end
  end
end
