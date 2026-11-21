module LocalBackups
  class CreateJob < Syrus::Host::BackgroundJob
    queue_as :low_priority_maintenance
    limits_concurrency to: 1, key: ->(*) { "local-backups:create" }, duration: 2.hours, on_conflict: :discard

    def perform(reason: "scheduled")
      backup = Creator.new.call(reason:)
      Retention.new.call
      OperationalEvents.emit("completed", backup_uuid: backup.uuid, stored_bytes: backup.stored_bytes)
      Syrus::Events.publish("local_backups.backup.completed", backup_uuid: backup.uuid, stored_bytes: backup.stored_bytes)
    rescue StandardError => e
      OperationalEvents.emit("failed", error_class: e.class.name)
      raise
    end
  end
end
