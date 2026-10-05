module CoverageOnMiss
  class Block
    def call(message:, log:, **)
      log.call("[coverage_analyze] threshold miss — failing step")
      raise Steps::Base::StepFailed, message
    end
  end
end
