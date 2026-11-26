module MainBranchHealth
  class Callbacks
    include Syrus::Host::Callbacks

    # Replaces the former core recurring.yml entry: fan out one health poll per
    # health-enabled repository every few minutes while the plugin is enabled.
    def self.on_tick
      PollAllMainBranchHealthJob.perform_later
    end
  end
end
