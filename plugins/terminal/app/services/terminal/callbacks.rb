module Terminal
  class Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      OrphanReaperJob.perform_later
    end
  end
end
