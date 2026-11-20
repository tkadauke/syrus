module LocalBackups
  class CreateJob < ApplicationJob
    queue_as :low_priority_maintenance
    limits_concurrency to: 1, key: ->(*) { "local-backups:create" }, duration: 2.hours, on_conflict: :discard

    def perform(reason: "scheduled")
      backup = Creator.new.call(reason:)
      Retention.new.call
      Rails.logger.info({ event: "local_backups.backup.completed", backup_uuid: backup.uuid, stored_bytes: backup.stored_bytes }.to_json)
    rescue StandardError => e
      Rails.logger.error({ event: "local_backups.backup.failed", error_class: e.class.name }.to_json)
      raise
    end
  end
end
