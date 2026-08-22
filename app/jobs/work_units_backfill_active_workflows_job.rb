class WorkUnitsBackfillActiveWorkflowsJob < ApplicationJob
  queue_as :maintenance

  def perform(limit: nil)
    WorkUnits::Backfill.active!(limit: limit)
  end
end
