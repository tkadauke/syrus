module WorkUnits
  class WorkflowCancellation
    def self.cancel!(workflow, reason:, artifacts: {}, by_work_unit: nil)
      new(workflow, reason: reason, artifacts: artifacts, by_work_unit: by_work_unit).cancel!
    end

    def initialize(workflow, reason:, artifacts:, by_work_unit:)
      @workflow = workflow
      @reason = reason.to_s
      @artifacts = artifacts || {}
      @by_work_unit = by_work_unit
    end

    def cancel!
      workflow.artifacts = workflow.artifacts.to_h.merge(artifacts)
      workflow.cancel! if workflow.may_cancel?
      workflow.save!
      workflow.work_unit&.preempt!(reason: reason, by_work_unit: by_work_unit)
      workflow
    end

    private

    attr_reader :workflow, :reason, :artifacts, :by_work_unit
  end
end
