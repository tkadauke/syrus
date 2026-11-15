module ScheduledTasks
  module SystemSchedules
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

      def fetch(key)
        definitions.fetch(key.to_s)
      rescue KeyError
        raise ArgumentError, "unknown system schedule: #{key}"
      end

      private

      def definitions = (@definitions ||= {})
    end
  end
end
