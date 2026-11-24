module Terminal
  class Callbacks
    include Syrus::Host::Callbacks

    def self.on_tick
      OrphanReaperJob.perform_later
    end
  end
end
