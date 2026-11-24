module OperatorBriefing
  class Callbacks
    include Syrus::Host::Callbacks

    def self.on_tick
      Scheduler.run!
    end
  end
end
