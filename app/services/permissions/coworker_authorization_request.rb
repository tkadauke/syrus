require "digest"

module Permissions
  class CoworkerAuthorizationRequest
    Result = Data.define(:request, :decision)

    def initialize(context:, descriptor:, arguments:, purpose: nil, action: nil, payload: {})
      @context = context
      @descriptor = descriptor
      @arguments = arguments.to_h
      @purpose = purpose
      @action = action
      @payload = payload
    end

    def call
      authorization = Permissions::Management.new(context.user).authorize(
        descriptor:, role: context.role, resource_scope:, arguments:,
        context: evaluation_context
      )
      decision = authorization.decision
      raise Mcp::Tools::AuthorizationSupport::AuthorizationError, "permission policy denies this operation" if denied?(decision)
      return Result.new(request: nil, decision:) if authorization.authorized?

      request = create_request(decision)
      Result.new(request:, decision:)
    end

    private

    attr_reader :context, :descriptor, :arguments, :purpose, :action, :payload

    def create_request(decision)
      fingerprint = InvocationFingerprint.call(descriptor:, arguments:)
      key = deduplication_key(decision, fingerprint)
      existing = ChatPendingAction.find_equivalent(key)
      return existing if existing

      ChatPendingAction.transaction do
        request = ChatPendingAction.create_or_find_authorization_request!(
          chat_session: context.chat_session,
          repository: context.repository,
          user: context.user,
          origin: context.run || context.chat_session,
          subject: context.agent_actor,
          runtime_role: context.role,
          action:,
          state: "pending",
          requested_by: "agent",
          deduplication_key: key,
          purpose:,
          payload:
        )
        populate_items(request, decision, fingerprint) if request.authorization_items.empty?
        request
      end
    end

    def populate_items(request, decision, fingerprint)
      operation = request.authorization_items.create!(
        common_attributes(decision).merge(
          kind: "operation",
          operation: identifier_name(decision.invocation.operation),
          operation_version: identifier_version(decision.invocation.operation),
          normalized_arguments: descriptor.redact(arguments),
          invocation_fingerprint: fingerprint,
          effects: decision.invocation.effects,
          risk: decision.invocation.risk,
          classifier_confidence: decision.invocation.classification.confidence,
          requested_durations: [ "invocation" ]
        )
      )
    end

    def common_attributes(decision)
      {
        capability: identifier_name(descriptor.capability),
        capability_version: identifier_version(descriptor.capability),
        resource_type: descriptor.resource_scope.type.to_s,
        resource_scope: decision.invocation.resource_scope,
        policy_chain: decision.chain.map(&:to_h),
        decisive_rule: decision.decisive_rule&.to_h || {},
        purpose:
      }
    end

    def resource_scope
      {}
    end

    def evaluation_context
      {
        role: context.role,
        agent_id: context.agent_actor.id,
        subject_selector_type: "agent",
        subject_selector_id: context.agent_actor.id.to_s,
        subject_repository_id: context.repository&.id
      }.compact
    end

    def denied?(decision) = decision.deny?

    def unversioned_capability = identifier_name(descriptor.capability)

    def identifier_name(identifier) = identifier.to_s.sub(/@v\d+\z/, "")
    def identifier_version(identifier) = identifier.to_s.match(/@v(\d+)\z/)[1].to_i

    def deduplication_key(decision, fingerprint)
      material = [ context.agent_actor.class.name, context.agent_actor.id, descriptor.capability,
        decision.invocation.operation, decision.invocation.resource_scope, fingerprint,
        context.job&.id || context.chat_session&.id ]
      "coworker-authorization:#{Digest::SHA256.hexdigest(JSON.generate(material))}"
    end
  end
end
