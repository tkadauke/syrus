module CoverageOnMiss
  class Warn < Base
    def call(workflow:, on_miss:, message:, log:)
      log.call("[coverage_analyze] threshold miss — warning only (on_miss: #{on_miss})")
    end
  end
end
