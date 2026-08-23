class WorkflowPhaseAdmissionJob < ApplicationJob
  queue_as :control_plane

  discard_on ActiveRecord::RecordNotFound

  def perform(workflow_id, step_id = nil)
    WorkUnits::DeferredPhaseResume.call(workflow_id, step_id)
  end
end
