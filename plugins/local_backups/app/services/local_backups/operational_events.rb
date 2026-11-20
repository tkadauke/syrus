module LocalBackups
  module OperationalEvents
    def self.emit(name, **attributes)
      payload = { event: "local_backups.backup.#{name}" }.merge(attributes.compact)
      Rails.logger.info(payload.to_json)
      ActiveSupport::Notifications.instrument(payload.fetch(:event), payload.except(:event))
    end
  end
end
