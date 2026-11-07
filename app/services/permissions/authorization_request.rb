require "digest"

module Permissions
  # Evaluates and persists an exact invocation request for any agent actor.
  # Actor-specific policy belongs in the descriptor/evaluator; this lifecycle
  # only records the canonical decision and resumable operation.
  class AuthorizationRequest
    RESULT_REUSE_WINDOW = 15.minutes
    Result = Data.define(:request, :decision, :reused_result) do
      def initialize(request:, decision:, reused_result: nil) = super
    end

    def initialize(context:, descriptor:, arguments:, purpose: nil, action: nil, payload: {}, force_request: false,
      request_on_ask: true)
      @context = context
      @descriptor = descriptor
      @arguments = arguments.to_h
      @purpose = purpose
      @action = action
      @payload = payload
      @force_request = force_request
      @request_on_ask = request_on_ask
    end

    def call
      authorization = Management.new(context.user).authorize(
        descriptor:, role: context.role, resource_scope: descriptor.resource_scope_for(arguments), arguments:,
        context: evaluation_context
      )
      decision = authorization.decision
      raise Mcp::Tools::AuthorizationSupport::AuthorizationError, "permission policy denies this operation" if decision.deny?
      return Result.new(request: nil, decision:) unless request_on_ask
      return Result.new(request: nil, decision:) if authorization.authorized? && !force_request

      reused = reusable_completed_request(decision)
      return Result.new(request: nil, decision:, reused_result: reused.payload["tool_result"]) if reused

      Result.new(request: create_request(decision), decision:)
    end

    private

    attr_reader :context, :descriptor, :arguments, :purpose, :action, :payload, :force_request, :request_on_ask

    def subject = context.agent_actor || context.user
    def origin = context.run || context.chat_session || context.job

    def reusable_completed_request(decision)
      return if force_request

      candidate = ChatPendingAction.where(deduplication_key: deduplication_key(decision, fingerprint), state: "confirmed")
        .where(confirmed_at: RESULT_REUSE_WINDOW.ago..).order(confirmed_at: :desc).first
      return unless candidate&.user_id == context.user.id && candidate.subject == subject
      return if candidate.payload.to_h["tool_result"].blank?

      candidate
    end

    def create_request(decision)
      key = deduplication_key(decision, fingerprint)
      existing = ChatPendingAction.find_equivalent(key)
      return existing if existing

      ChatPendingAction.transaction do
        request = ChatPendingAction.create_or_find_authorization_request!(
          chat_session: context.chat_session, repository: context.repository, user: context.user,
          origin:, subject:, runtime_role: context.role, action:, state: "pending",
          requested_by: "agent", deduplication_key: key, purpose:, payload:
        )
        request.authorization_items.create!(item_attributes(decision)) if request.authorization_items.empty?
        request
      end
    end

    def item_attributes(decision)
      {
        kind: "operation", capability: identifier_name(descriptor.capability),
        capability_version: identifier_version(descriptor.capability),
        operation: identifier_name(decision.invocation.operation),
        operation_version: identifier_version(decision.invocation.operation),
        resource_type: descriptor.resource_scope.type.to_s,
        resource_scope: decision.invocation.resource_scope,
        normalized_arguments: descriptor.redact(arguments), invocation_fingerprint: fingerprint,
        effects: decision.invocation.effects, risk: decision.invocation.risk,
        classifier_confidence: decision.invocation.classification.confidence,
        policy_chain: decision.chain.map(&:to_h), decisive_rule: decision.decisive_rule&.to_h || {},
        purpose:, requested_durations: requested_durations
      }
    end

    def requested_durations
      available = descriptor.authority_durations.map(&:to_s)
      applicable = if context.chat_session
        %w[ invocation chat_session permanent ]
      elsif context.job
        %w[ invocation job permanent ]
      else
        %w[ invocation permanent ]
      end
      available & applicable
    end

    def evaluation_context
      selector_type, selector_id = subject_selector
      {
        role: context.role, agent_id: context.agent_actor&.id,
        agent_actor: context.agent_actor,
        subject_selector_type: selector_type, subject_selector_id: selector_id,
        subject_repository_id: context.repository&.id, chat_session_id: context.chat_session&.id,
        job_id: context.job&.id, workflow_id: context.workflow&.id, run_id: context.run&.id
      }.compact
    end

    def subject_selector
      return [ "agent", context.agent_actor.id.to_s ] if context.agent_actor
      matching = PermissionRule::SUBJECT_SELECTORS.find { |_type, metadata| metadata[:role] == context.role }
      return [ matching.first, nil ] if matching

      [ "workflow_role", context.role ]
    end

    def fingerprint = @fingerprint ||= InvocationFingerprint.call(descriptor:, arguments:)
    def identifier_name(identifier) = identifier.to_s.sub(/@v\d+\z/, "")
    def identifier_version(identifier) = identifier.to_s[/@v(\d+)\z/, 1].to_i

    def deduplication_key(decision, invocation_fingerprint)
      lifetime = context.job&.id || context.chat_session&.id || context.run&.id
      material = [ subject.class.polymorphic_name, subject.id, context.role, descriptor.capability,
        decision.invocation.operation, decision.invocation.resource_scope, invocation_fingerprint, lifetime ]
      "authorization:#{Digest::SHA256.hexdigest(JSON.generate(material))}"
    end
  end
end
