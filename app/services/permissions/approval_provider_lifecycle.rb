module Permissions
  # Applies an AI approval provider's decision to an authorization request that
  # is already pending. It never opens a second request: allow approves the one
  # operation item and issues its exact-invocation authority atomically, deny
  # rejects only this attempt (no rule, lease, or cooldown is created), and
  # anything uncertain or failing leaves the request with the human reviewer.
  # An identical resubmission is evaluated again only when the transcript
  # evidence it carries differs from what was last evaluated.
  class ApprovalProviderLifecycle
    EVALUATED_EVENT = "ai_approval_evaluated".freeze

    Result = Data.define(:status, :request, :item, :invocation, :authorization) do
      def approved? = status == :approved
      def denied? = status == :denied
      def escalated? = status == :escalated
      def unchanged? = status == :unchanged
      def skipped? = status == :skipped
    end

    def self.call(...) = new(...).call

    def initialize(request:, tool_name:, transcript: [], repository_guidance: nil, delegations: nil,
      providers: nil, ceiling_rules: [])
      @request = request
      @tool_name = tool_name.to_s
      @transcript = Array(transcript)
      @repository_guidance = repository_guidance
      @authorizer_options = { delegations:, providers:, ceiling_rules: }.compact
    end

    def call
      item = eligible_item
      return skipped(item) unless item

      digest = evidence_digest(item)
      return unchanged(item) if last_evaluation(item)&.dig("evidence_digest") == digest

      authorization = authorize(item)
      apply(item, authorization, digest)
    rescue StandardError => error
      Rails.logger.warn("[ApprovalProviderLifecycle] #{error.class}: #{error.message}")
      Result.new(status: :escalated, request: @request, item: item, invocation: nil, authorization: nil)
    end

    private

    # Only a plain single-operation request is delegable: capability-possession
    # prerequisites would let an AI principal expand authority.
    def eligible_item
      return unless @request.authorization_request? && @request.pending? && @request.actionable?

      items = @request.authorization_items.to_a
      return unless items.one?

      item = items.first
      item if item.kind == "operation" && item.actionable? && item.invocation_fingerprint.present? &&
        item.requested_durations.include?("invocation")
    end

    def authorize(item)
      provider_request = ApprovalProviderRequest.new(
        owner: @request.user, capability: item.capability, operation: item.operation,
        resource_type: item.resource_type, resource_scope: item.resource_scope, effects: item.effects,
        invocation_fingerprint: item.invocation_fingerprint, transcript: @transcript,
        tool_call: { name: @tool_name, arguments: item.normalized_arguments },
        policy_chain: item.policy_chain, repository_guidance: @repository_guidance
      )
      ApprovalProviderAuthorizer.call(request: provider_request, **@authorizer_options)
    end

    def apply(item, authorization, digest)
      @request.with_lock do
        item.reload
        return stale(item) unless @request.reload.pending? && item.actionable?

        record_evaluation!(item, authorization, digest)
        if authorization.allowed? then approve!(item, authorization)
        elsif authorization.denied? then deny!(item, authorization)
        else Result.new(status: :escalated, request: @request, item:, invocation: nil, authorization:)
        end
      end
    end

    def approve!(item, authorization)
      item.decide!("approved", principal: authorization.delegation, duration: "invocation",
        reason: authorization.decision.rationale)
      @request.update!(state: "confirmed")
      invocation = AuthorizedInvocation.issue!(
        pending_action_item: item, tool_name: @tool_name,
        audit_payload: { "approval_provider" => audit(authorization), "delegation_id" => authorization.delegation.id }
      )
      Result.new(status: :approved, request: @request, item:, invocation:, authorization:)
    end

    def deny!(item, authorization)
      item.decide!("denied", principal: authorization.delegation, reason: authorization.decision.rationale)
      @request.update!(state: "rejected")
      Result.new(status: :denied, request: @request, item:, invocation: nil, authorization:)
    end

    def record_evaluation!(item, authorization, digest)
      @request.transitions.create!(
        pending_action_item: item, event_type: EVALUATED_EVENT, from_state: item.state, to_state: item.state,
        actor: authorization.delegation,
        metadata: { "evidence_digest" => digest, "outcome" => authorization.decision.outcome.to_s,
                    "provider_outcome" => authorization.decision.provider_outcome,
                    "approval_provider" => audit(authorization) }.compact
      )
    end

    def audit(authorization)
      authorization.audit_artifact || { "decision" => authorization.decision.to_h.deep_stringify_keys }
    end

    def last_evaluation(item)
      item.transitions.where(event_type: EVALUATED_EVENT).order(:sequence).last&.metadata
    end

    # Keyed digest over the complete (unredacted) evidence, so secret-bearing
    # changes still trigger reconsideration while only the digest is persisted.
    def evidence_digest(item)
      canonical = canonicalize([ item.invocation_fingerprint, @transcript, @repository_guidance.to_s ])
      key = Rails.application.key_generator.generate_key("approval-provider-evidence-digest")
      "hmac-sha256:#{OpenSSL::HMAC.hexdigest("SHA256", key, canonical.to_json)}"
    end

    def canonicalize(value)
      case value
      when Hash then value.to_h { |key, item| [ key.to_s, canonicalize(item) ] }.sort.to_h
      when Array then value.map { |item| canonicalize(item) }
      when Symbol then value.to_s
      else value
      end
    end

    def skipped(item) = Result.new(status: :skipped, request: @request, item:, invocation: nil, authorization: nil)
    def unchanged(item) = Result.new(status: :unchanged, request: @request, item:, invocation: nil, authorization: nil)
    def stale(item) = Result.new(status: :skipped, request: @request, item:, invocation: nil, authorization: nil)
  end
end
