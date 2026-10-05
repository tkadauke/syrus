module CoverageOnMiss
  class Schedule
    def call(workflow:, log:, **)
      CoverageScheduleTriggerJob.perform_later(workflow.id)
      log.call("[coverage_analyze] threshold miss — scheduled coverage fix job")
    end
  end
end
