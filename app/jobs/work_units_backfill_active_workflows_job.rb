class WorkUnitsBackfillActiveWorkflowsJob < ApplicationJob
  DEFAULT_LIMIT = 100

  queue_as :low_priority_maintenance

  def perform(limit: DEFAULT_LIMIT)
    WorkUnits::Backfill.active!(limit: limit)
  end
end
