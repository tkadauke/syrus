module LocalBackups
  module Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      MaintenanceJob.perform_later
      CreateJob.perform_later(reason: "scheduled") if ENV.fetch("SYRUS_BACKUP_SCHEDULE_ENABLED", "1") == "1"
    end
  end
end
