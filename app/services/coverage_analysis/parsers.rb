module CoverageAnalysis
  module Parsers
    REGISTRY = {
      "lcov"      => -> { CoverageAnalysis::Parsers::Lcov },
      "cobertura" => -> { CoverageAnalysis::Parsers::Cobertura }
    }.freeze

    module_function

    def for(format)
      loader = REGISTRY[format.to_s.downcase]
      raise ArgumentError, "unsupported coverage format: #{format.inspect}" unless loader

      loader.call
    end
  end
end
