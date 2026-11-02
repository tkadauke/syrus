module Permissions
  class ApprovalProviderAuthorizer
    HUMAN_ONLY_CAPABILITY = "syrus.permissions@v1"
    MINIMUM_ALLOW_CONFIDENCE = 0.8

    Result = Data.define(:decision, :delegation, :provider, :request, :evidence) do
      def allowed? = decision.allow?
      def denied? = decision.deny?
      def escalated? = decision.escalate?
      def authority_duration = :invocation
      def invocation_fingerprint = request.invocation_fingerprint
    end

    def self.call(...) = new(...).call

    def initialize(request:, delegations: nil, providers: nil, ceiling_rules: [])
      @request = request
      @delegations = delegations || ApprovalProviderDelegation.active.where(owner_user: request.owner)
      @providers = providers || Syrus::PluginRegistry.providers_for(:approval_provider)
      @ceiling_rules = Array(ceiling_rules)
    end

    def call
      return escalated(:human_only, "This invocation requires a human decision") if human_only?

      eligible = @delegations.select { |candidate| candidate.covers?(@request) }
      delegation = eligible.find do |candidate|
        @providers.any? { |provider| provider.provider_key.to_s == candidate.provider_key }
      end
      delegation ||= eligible.first
      return escalated(:not_delegated, "No explicit AI approval delegation covers this invocation") unless delegation

      provider = @providers.find { |candidate| candidate.provider_key.to_s == delegation.provider_key }
      return escalated(:provider_unavailable, "The delegated approval provider is unavailable", delegation:) unless provider
      return escalated(:ceiling, "A core, plugin, instance, or resource ceiling requires human review", delegation:, provider:) if ceiling_blocks?

      evidence = ApprovalProviderEvidence.new(request: @request, provider:)
      decision = ApprovalProviderDecision.coerce(provider.decide(evidence))
      if !decision.escalate? && decision.confidence < MINIMUM_ALLOW_CONFIDENCE
        return escalated(:uncertain, "The approval provider was not confident enough to decide", delegation:, provider:)
      end
      if !decision.escalate? && decision.provider_outcome.present?
        return escalated(decision.provider_outcome, "The approval provider requires human review", delegation:, provider:)
      end

      Result.new(decision:, delegation:, provider:, request: @request, evidence:)
    rescue StandardError => error
      Rails.logger.warn("[ApprovalProviderAuthorizer] #{error.class}: #{error.message}")
      escalated(:invalid_provider_output, "The approval provider could not return a valid decision", delegation:, provider:)
    end

    private

    def human_only?
      @request.capability == HUMAN_ONLY_CAPABILITY ||
        (@request.effects & ApprovalProviderDelegation::CORE_HUMAN_ONLY_EFFECTS).any?
    end

    def ceiling_blocks?
      policy_ceiling_blocks? || @ceiling_rules.any? { |rule| !rule.call(@request) }
    end

    def policy_ceiling_blocks?
      @request.policy_chain.any? do |entry|
        rule = entry["rule"]
        next false unless rule.is_a?(Hash) && rule["delegable"] == false

        (entry["policy"] || rule["policy"]).to_s != "allow"
      end
    end

    def escalated(code, rationale, delegation: nil, provider: nil)
      decision = ApprovalProviderDecision.new(outcome: :escalate, rationale:,
        policy_factors: [ code ], confidence: 1.0, evidence: {}, provider_outcome: code)
      Result.new(decision:, delegation:, provider:, request: @request, evidence: nil)
    end
  end
end
