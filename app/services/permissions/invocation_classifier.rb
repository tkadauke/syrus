module Permissions
  class InvocationClassifier
    Result = Data.define(:operation, :effects, :risk, :confidence, :fallback, :reason) do
      def fallback? = fallback
    end

    def self.call(descriptor:, arguments:)
      classified = descriptor.classify(arguments).to_h.transform_keys(&:to_sym)
      operation = classified.fetch(:operation, descriptor.operation).to_s
      effects = Array(classified.fetch(:effects, descriptor.effects)).map(&:to_sym).uniq
      risk = classified.fetch(:risk, descriptor.risk).to_sym
      confidence = classified.fetch(:confidence, :certain).to_sym
      raise ArgumentError unless operation.match?(/@v[1-9]\d*\z/)
      raise ArgumentError unless (effects - CapabilityDescriptor::EFFECTS).empty?
      raise ArgumentError unless CapabilityDescriptor::RISKS.include?(risk)
      return maximum(descriptor, :ambiguous_classifier) unless confidence == :certain

      Result.new(operation:, effects: effects.freeze, risk:, confidence:, fallback: false, reason: nil)
    rescue StandardError
      maximum(descriptor, :classifier_failure)
    end

    def self.maximum(descriptor, reason)
      Result.new(operation: descriptor.operation, effects: descriptor.effects, risk: descriptor.risk,
        confidence: :ambiguous, fallback: true, reason: reason)
    end
    private_class_method :maximum
  end
end
