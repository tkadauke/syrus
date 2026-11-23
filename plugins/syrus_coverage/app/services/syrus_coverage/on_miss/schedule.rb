module SyrusCoverage::OnMiss
  class Schedule
    def call(workflow:, log:, **)
      SyrusCoverage::ScheduleTriggerJob.perform_later(workflow.id)
      log.call("[coverage_analyze] threshold miss — scheduled coverage fix job")
    end
  end
end
