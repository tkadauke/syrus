require_dependency "tool_payload_redactor"

module Permissions
  class ApprovalProviderDecision
    OUTCOMES = %i[allow deny escalate].freeze

    attr_reader :outcome, :rationale, :policy_factors, :confidence, :evidence, :provider_outcome

    def initialize(outcome:, rationale:, policy_factors:, confidence:, evidence:, provider_outcome: nil)
      @outcome = outcome.to_sym
      @rationale = rationale.to_s
      @policy_factors = Array(policy_factors).map(&:to_s).freeze
      @confidence = Float(confidence)
      @evidence = ToolPayloadRedactor.redact(evidence.to_h.deep_stringify_keys).freeze
      @provider_outcome = provider_outcome&.to_s
      validate!
      freeze
    end

    def allow? = outcome == :allow
    def deny? = outcome == :deny
    def escalate? = outcome == :escalate

    def to_h = { outcome:, rationale:, policy_factors:, confidence:, evidence:, provider_outcome: }.compact

    def self.coerce(value)
      return value if value.is_a?(self)

      new(**value.to_h.symbolize_keys)
    end

    private

    def validate!
      raise ArgumentError, "outcome must be allow, deny, or escalate" unless OUTCOMES.include?(outcome)
      raise ArgumentError, "rationale is required" if rationale.blank?
      raise ArgumentError, "confidence must be between 0 and 1" unless confidence.between?(0.0, 1.0)
    end
  end
end
