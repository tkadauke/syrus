class WorkflowAdmissionBudget
  class PredictionSource
    REGISTRY = {}

    def self.register(name, implementation)
      REGISTRY[name] = implementation
    end

    def self.for(name)
      REGISTRY.fetch(name.to_s, DefaultsOnly).new
    end

    def confidence
      raise NotImplementedError
    end

    class CommandAttributed < PredictionSource
      def confidence = "process_attributed"
    end

    class HostCorrelated < PredictionSource
      def confidence = "lower_confidence_fallback"
    end

    class DefaultsOnly < PredictionSource
      def confidence = "conservative_defaults"
    end

    register "command_attributed", CommandAttributed
    register "host_correlated", HostCorrelated
    register "defaults_only", DefaultsOnly
  end
end
