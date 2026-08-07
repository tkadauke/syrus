module WorkEngine
  class ReconcileJob < ApplicationJob
    queue_as :control_plane
    limits_concurrency(
      to: 1,
      key: ->(source:, job_id: nil, workflow_id: nil, run_id: nil) {
        if job_id.present?
          "job:#{job_id}"
        elsif workflow_id.present?
          "workflow:#{workflow_id}"
        elsif run_id.present?
          "run:#{run_id}"
        else
          "global"
        end
      },
      duration: 10.minutes,
      on_conflict: :discard
    )

    def perform(source:, job_id: nil, workflow_id: nil, run_id: nil)
      result = Reconciler.call(
        source: source,
        job_id: job_id,
        workflow_id: workflow_id,
        run_id: run_id,
        execute_repairs: true
      )
      Admin::StuckItemsCache.write_from_result(result: result) if job_id.blank? && workflow_id.blank? && run_id.blank?
      result
    end
  end
end
