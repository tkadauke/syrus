module LocalBackups
  class MaintenanceJob < Syrus::Host::BackgroundJob
    queue_as :cleanup

    def perform
      PartialCleanup.new.call
      # Before retention, so a backup an abandoned upload held is reclaimable
      # in the same pass.
      AbandonedReplicationSweep.new.call
      Retention.new.call
    end
  end
end
