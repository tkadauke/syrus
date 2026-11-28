module ScheduledTasks
  module SystemSchedules
    # A system schedule whose definition is not registered in this process,
    # even after the plugin installer has synced. Deliberately not an
    # ArgumentError: callers rescue ArgumentError to mean "this schedule's
    # expression or arguments do not apply right now", and an unregistered
    # definition must never read as a quiet "not due".
    class UnknownSystemSchedule < StandardError; end

    class Definition
      def prompt(task:, target_date:) = raise NotImplementedError

      def catch_up_due?(task:, now:) = false

      def failure_date(task:, now:) = nil

      def failure_recorded(task:, date:, reason:) = nil

      def overdue?(task:, now:) = false
    end

    class << self
      def register(key, definition:)
        definitions[key.to_s] = definition
      end

      # Definitions are registered by plugin installs (for example, the
      # coworkers plugin registers journaling while it is enabled). Syncing
      # on read makes sure this process has run those installs before a
      # lookup decides the key is unknown; it is a no-op when nothing moved.
      def fetch(key)
        Syrus::Host::Installer.sync!
        definitions.fetch(key.to_s)
      rescue KeyError
        raise UnknownSystemSchedule, "unknown system schedule: #{key}"
      end

      private

      def definitions = (@definitions ||= {})
    end
  end
end
