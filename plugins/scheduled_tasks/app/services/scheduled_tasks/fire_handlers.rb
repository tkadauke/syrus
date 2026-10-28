module ScheduledTasks
  module FireHandlers
    Entry = Data.define(:target, :matcher, :handler)

    @entries = []
    @mutex = Mutex.new

    class << self
      def register(target:, handler:, &matcher)
        raise ArgumentError, "target matcher required" unless matcher

        entry = Entry.new(target: target.to_sym, matcher: matcher, handler: handler)
        @mutex.synchronize { @entries << entry }

        -> { @mutex.synchronize { @entries.delete(entry) } }
      end

      def for(task)
        Syrus::Installer.sync!
        entries = @mutex.synchronize { @entries.reverse.dup }
        entry = entries.find { |candidate| candidate.matcher.call(task) }
        (entry&.handler || ScheduledTasks::FireHandlers::Default).new(task)
      end

      def behavior_applicable?(task, behavior)
        self.for(task).applicable_behaviors.include?(behavior.to_sym)
      end
    end
  end
end
