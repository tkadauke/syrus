module CoverageOnMiss
  class Warn
    def call(on_miss:, log:, **)
      log.call("[coverage_analyze] threshold miss — warning only (on_miss: #{on_miss})")
    end
  end
end
