module CoverageOnMiss
  class Block < Base
    def call(workflow:, on_miss:, message:, log:)
      log.call("[coverage_analyze] threshold miss — failing step")
      raise Steps::Base::StepFailed, message
    end
  end
end
