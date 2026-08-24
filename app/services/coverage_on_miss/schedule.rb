module CoverageOnMiss
  class Schedule < Base
    def call(workflow:, on_miss:, message:, log:)
      CoverageScheduleTriggerJob.perform_later(workflow.id)
      log.call("[coverage_analyze] threshold miss — scheduled coverage fix job")
    end
  end
end
