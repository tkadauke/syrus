module SyrusCoverage::OnMiss
  class Block
    def call(message:, log:, **)
      log.call("[coverage_analyze] threshold miss — failing step")
      raise Syrus::Host::StepFailed, message
    end
  end
end
