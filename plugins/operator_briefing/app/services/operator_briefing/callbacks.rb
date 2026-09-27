module OperatorBriefing
  class Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      Scheduler.run!
    end
  end
end
