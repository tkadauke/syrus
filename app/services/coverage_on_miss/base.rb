module CoverageOnMiss
  class Base
    def call(workflow:, on_miss:, message:, log:)
      raise NotImplementedError
    end
  end
end
