module Terminal
  class OrphanReaperJob < Syrus::Host::PluginJob
    plugin :terminal

    def perform
      OrphanReaper.run!
    end
  end
end
