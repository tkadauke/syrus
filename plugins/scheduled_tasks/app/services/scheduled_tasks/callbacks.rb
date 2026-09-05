module ScheduledTasks
  # Drives the poll that fires due schedules.
  #
  # This was an entry in the host's config/recurring.yml, which is not
  # something a plugin can add. `tick_interval` plus this callback is the
  # plugin-owned equivalent, and it stops when the plugin is disabled --
  # which the YAML entry never did.
  class Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      PollScheduledTasksJob.perform_later
    end
  end
end
