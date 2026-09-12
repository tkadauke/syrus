class MaintenanceTaskDiscoveryJob < ApplicationJob
  queue_as :low_priority_maintenance

  def perform
    MaintenanceTasks::Discovery.call
  end
end
