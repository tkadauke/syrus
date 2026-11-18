module Terminal
  class OrphanReaperJob < PluginJob
    plugin_name "terminal"
    queue_as :cleanup

    def perform
      OrphanReaper.run!
    end
  end
end
