module Coverage
  module Parsers
    REGISTRY = {
      "lcov"      => -> { Coverage::Parsers::Lcov },
      "cobertura" => -> { Coverage::Parsers::Cobertura }
    }.freeze

    module_function

    def for(format)
      loader = REGISTRY[format.to_s.downcase]
      raise ArgumentError, "unsupported coverage format: #{format.inspect}" unless loader

      loader.call
    end
  end
end
