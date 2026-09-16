module VideoWalkthroughs
  # Retention runs on the plugin's own tick rather than the host's
  # recurring.yml, so deleting the plugin deletes the schedule with it.
  module Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      PruneJob.perform_later
      nil
    end
  end
end
