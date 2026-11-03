require "digest"

module Permissions
  # A coworker's proactive request for authority for ITSELF. Creating the
  # request grants nothing: it produces (or reuses) the same durable
  # authorization request the owner sees in chats and the approval inbox, and
  # authority only exists once the owner approves it through
  # CoworkerAuthorizationDecision. The subject is always the calling coworker;
  # there is no parameter that could name another one.
  class CoworkerPermissionRequest
    ACTION = "coworker_permission_request".freeze
    # Narrowest first. Job authority is never offered to a coworker request:
    # its origin is a chat or run, which SmartDecision does not map to a Job.
    DURATIONS = %w[ chat_session permanent ].freeze
    MAX_PENDING = 3
    MAX_PER_HOUR = 6
    RENEWAL_COOLDOWN = 1.hour
    PROTECTED_CAPABILITY = "syrus.permissions".freeze

    class Rejected < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    Result = Data.define(:status, :request, :offered_durations, :requested_duration) do
      def created? = status == :created
    end

    def initialize(context:, capability:, operation:, purpose:, resource_scope: {}, constraints: {}, duration: nil, origin_message_id: nil)
      @context = context
      @capability = capability.to_s
      @operation = operation.to_s
      @purpose = purpose.to_s.strip
      @resource_scope = resource_scope.respond_to?(:to_unsafe_h) ? resource_scope.to_unsafe_h : resource_scope.to_h
      @constraints = constraints.respond_to?(:to_unsafe_h) ? constraints.to_unsafe_h : constraints.to_h
      @duration = duration.presence&.to_s
      @origin_message_id = origin_message_id
    end

    def call
      assert_coworker!
      raise Rejected.new(:purpose_required, "purpose is required") if purpose.blank?
      descriptor = find_descriptor
      offered = offered_durations(descriptor)
      raise Rejected.new(:no_supported_duration, no_duration_message(descriptor)) if offered.empty?

      requested = duration || offered.first
      unless offered.include?(requested)
        raise Rejected.new(:duration_not_offered, "requested duration is not offered; choose one of: #{offered.join(', ')}")
      end

      scope = normalized_scope(descriptor)
      return already_authorized(descriptor, scope, offered, requested) if authorized?(descriptor, scope)

      key = deduplication_key(descriptor, scope)
      existing = ChatPendingAction.find_equivalent(key)
      if existing
        audit(:coworker_permission_request_deduplicated, existing, requested)
        return Result.new(status: :deduplicated, request: existing, offered_durations: offered, requested_duration: requested)
      end

      enforce_limits!(key)
      request = create_request!(descriptor, scope, key, offered, requested)
      audit(:coworker_permission_requested, request, requested)
      Result.new(status: :created, request:, offered_durations: offered, requested_duration: requested)
    end

    private

    attr_reader :context, :capability, :operation, :purpose, :resource_scope, :constraints, :duration, :origin_message_id

    def coworker = context.agent_actor
    def owner = context.user

    def assert_coworker!
      return if context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]) && coworker &&
        RuleDraft.agent_subject_class(coworker.class.name) && coworker.owner_user_id == owner.id

      raise Rejected.new(:not_a_coworker, "only a coworker can request authority for itself")
    end

    def find_descriptor
      descriptor = Catalog.find!(capability:, operation:)
      if descriptor.capability.sub(/@v\d+\z/, "") == PROTECTED_CAPABILITY.sub(/@v\d+\z/, "")
        raise Rejected.new(:protected_capability, "permission administration cannot be requested by a coworker")
      end
      unless descriptor.requestable_roles.include?(context.role)
        raise Rejected.new(:role_not_eligible, "this operation cannot be granted to a coworker")
      end

      descriptor
    rescue Catalog::UnknownCapability
      raise Rejected.new(:unknown_capability, "unknown permission capability or operation")
    end

    def draft_for(descriptor, requested_duration)
      RuleDraft.new(user: owner, attributes: {
        "policy" => "allow", "duration" => requested_duration, "role" => context.role,
        "subject_selector_type" => "agent", "subject_selector_id" => coworker.id.to_s,
        "subject_type" => coworker.class.name, "subject_repository_id" => context.repository&.id,
        "capability" => descriptor.capability, "operation" => descriptor.operation,
        "resource_scope" => resource_scope, "constraints" => constraints,
        "chat_session_id" => context.chat_session&.id
      })
    end

    # The same canonical preview the owner will apply, so a duration the
    # descriptor or an owner policy ceiling refuses is never offered.
    def offered_durations(descriptor)
      DURATIONS.select do |candidate|
        preview = draft_for(descriptor, candidate).preview
        preview.valid? && preview.warnings.empty?
      end
    end

    def no_duration_message(descriptor)
      errors = DURATIONS.flat_map { |candidate| draft_for(descriptor, candidate).preview.errors }
      detail = errors.filter_map { |error| error[:message] || error["message"] }.uniq.first(3).join("; ")
      "no supported duration for this request#{": #{detail}" if detail.present?}"
    end

    def normalized_scope(descriptor)
      descriptor.resource_scope.normalize(resource_scope, context: { user: owner }).value
    end

    def evaluation_context
      {
        role: context.role, agent_id: coworker.id, subject_selector_type: "agent",
        subject_selector_id: coworker.id.to_s, subject_repository_id: context.repository&.id,
        chat_session_id: context.chat_session&.id
      }.compact
    end

    def authorized?(descriptor, scope)
      Management.new(owner).authorize(descriptor:, role: context.role, resource_scope: scope,
        arguments: constraints, context: evaluation_context).authorized?
    rescue ArgumentError
      false
    end

    def already_authorized(_descriptor, _scope, offered, requested)
      Result.new(status: :already_authorized, request: nil, offered_durations: offered, requested_duration: requested)
    end

    def deduplication_key(descriptor, scope)
      material = [ coworker.class.name, coworker.id, owner.id, context.repository&.id, descriptor.capability,
        descriptor.operation, scope, constraints.deep_stringify_keys.sort.to_h ]
      "coworker-permission-request:#{Digest::SHA256.hexdigest(JSON.generate(canonical(material)))}"
    end

    def canonical(value)
      case value
      when Hash then value.to_h { |key, item| [ key.to_s, canonical(item) ] }.sort.to_h
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def requests
      ChatPendingAction.where(request_kind: "authorization_request", action: ACTION,
        subject_type: coworker.class.name, subject_id: coworker.id)
    end

    def enforce_limits!(key)
      denied = requests.where(deduplication_key: key, state: "rejected").where(rejected_at: RENEWAL_COOLDOWN.ago..).exists?
      limited = if denied
        [ :recently_denied, "the owner denied an equivalent request moments ago; do not ask again right now" ]
      elsif requests.where(state: "pending").count >= MAX_PENDING
        [ :too_many_pending, "too many permission requests are already waiting for the owner" ]
      elsif requests.where(created_at: 1.hour.ago..).count >= MAX_PER_HOUR
        [ :rate_limited, "permission request limit reached; try again later" ]
      end
      return unless limited

      CoworkerAudit.record!(:coworker_permission_request_rate_limited, owner:, coworker:,
        reason: limited.first.to_s, capability:, operation:)
      raise Rejected.new(*limited)
    end

    def create_request!(descriptor, scope, key, offered, requested)
      ChatPendingAction.transaction do
        request = ChatPendingAction.create_or_find_authorization_request!(
          chat_session: context.chat_session, repository: context.repository, user: owner,
          origin: context.run || context.chat_session, subject: coworker, runtime_role: context.role,
          action: ACTION, state: "pending", requested_by: "agent", deduplication_key: key, purpose:,
          payload: { "requested_duration" => requested, "approval_policy" => "queue", "approval_inbox" => true,
                     "origin_message_id" => origin_message_id,
                     "actor" => Mcp::Tools::AuthorizationSupport.approval_actor(coworker) }.compact
        )
        request.authorization_items.create!(item_attributes(descriptor, scope, offered)) if request.authorization_items.empty?
        request
      end
    end

    def item_attributes(descriptor, scope, offered)
      {
        kind: "operation", capability: descriptor.capability.sub(/@v\d+\z/, ""),
        capability_version: descriptor.capability[/@v(\d+)\z/, 1].to_i,
        operation: descriptor.operation.sub(/@v\d+\z/, ""), operation_version: descriptor.operation[/@v(\d+)\z/, 1].to_i,
        resource_type: descriptor.resource_scope.type.to_s, resource_scope: scope,
        normalized_arguments: constraints.deep_stringify_keys,
        invocation_fingerprint: Digest::SHA256.hexdigest(JSON.generate(canonical([ descriptor.operation, scope, constraints ]))),
        effects: descriptor.effects, risk: descriptor.risk.to_s, purpose:, requested_durations: offered
      }
    end

    def audit(event, request, requested)
      CoworkerAudit.record!(event, owner:, coworker:, authorization_request_id: request.id,
        capability:, operation:, requested_duration: requested, repository_id: context.repository&.id)
    end
  end
end
