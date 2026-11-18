module Terminal
  class OrphanReaperJob < PluginJob
    queue_as :cleanup

    def perform
      OrphanReaper.run!
    end
  end
end
