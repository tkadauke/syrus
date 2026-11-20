module LocalBackups
  class MaintenanceJob < ApplicationJob
    queue_as :cleanup

    def perform
      PartialCleanup.new.call
      Retention.new.call
    end
  end
end
