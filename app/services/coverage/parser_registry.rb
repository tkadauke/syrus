module Coverage
  class ParserRegistry
    REGISTRY = {}

    def self.register(format, parser_class)
      REGISTRY[format.to_s] = parser_class
    end

    def self.for(format)
      REGISTRY[format.to_s]
    end

    def self.formats
      REGISTRY.keys
    end
  end
end
