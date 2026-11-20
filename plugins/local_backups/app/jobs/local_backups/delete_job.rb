module LocalBackups
  class DeleteJob < Syrus::Host::BackgroundJob
    queue_as :cleanup

    def perform(backup_id)
      Retention.new.delete!(Backup.find(backup_id))
    end
  end
end
