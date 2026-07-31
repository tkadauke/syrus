module WorkEngine
  class ReconcileJob < ApplicationJob
    queue_as :default

    def perform(source:, job_id: nil, workflow_id: nil, run_id: nil)
      Reconciler.call(source: source, job_id: job_id, workflow_id: workflow_id, run_id: run_id)
    end
  end
end
