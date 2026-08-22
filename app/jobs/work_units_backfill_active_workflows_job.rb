class WorkUnitsBackfillActiveWorkflowsJob < ApplicationJob
  queue_as :low_priority_maintenance

  def perform(limit: nil)
    WorkUnits::Backfill.active!(limit: limit)
  end
end
