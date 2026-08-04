class WorkflowPhaseAdmissionJob < ApplicationJob
  queue_as :control_plane

  discard_on ActiveRecord::RecordNotFound

  def perform(workflow_id, step_id = nil)
    StepDispatcher.resume_deferred_phase(workflow_id, step_id)
  end
end
