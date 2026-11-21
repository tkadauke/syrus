module LocalBackups
  class MaintenanceJob < Syrus::Host::BackgroundJob
    queue_as :cleanup

    def perform
      PartialCleanup.new.call
      Retention.new.call
    end
  end
end
