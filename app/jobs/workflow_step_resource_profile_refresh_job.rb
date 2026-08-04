class WorkflowStepResourceProfileRefreshJob < ApplicationJob
  include SkipIfPending

  queue_as :default

  def perform
    WorkflowStepResourceProfile.refresh_all!
  end
end
