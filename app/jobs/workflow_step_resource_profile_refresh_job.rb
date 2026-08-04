class WorkflowStepResourceProfileRefreshJob < ApplicationJob
  include SkipIfPending

  queue_as :low_priority_maintenance

  def perform
    WorkflowStepResourceProfile.refresh_all!
  end
end
