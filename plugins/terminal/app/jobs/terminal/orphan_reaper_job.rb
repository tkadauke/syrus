module Terminal
  class OrphanReaperJob < PluginJob
    plugin :terminal

    def perform
      OrphanReaper.run!
    end
  end
end
