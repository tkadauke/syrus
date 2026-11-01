module Permissions
  class AuthorityGrant
    DURATIONS = {
      invocation: "Permissions::AuthorityGrant::Invocation",
      chat_session: "Permissions::AuthorityGrant::ChatSessionScope",
      job: "Permissions::AuthorityGrant::JobScope",
      permanent: "Permissions::AuthorityGrant::Permanent"
    }.freeze

    def self.issue!(duration:, **attributes)
      DURATIONS.fetch(duration.to_sym).constantize.new(**attributes).issue!
    end

    class Base
      AUTONOMY_RANK = CapabilityDescriptor::AUTONOMY_CEILINGS.each_with_index.to_h.freeze

      def initialize(descriptor:, owner:, actor:, subject_selector_type:, subject_selector_id: nil,
        subject_repository: nil, role:, resource_scope:, rules: [], context: {}, arguments: {}, constraints: {}, source: nil,
        expires_at: nil, max_uses: nil, **lifecycle)
        @descriptor = descriptor
        @owner = owner
        @actor = actor
        @subject_selector_type = subject_selector_type.to_s
        @subject_selector_id = subject_selector_id&.to_s
        @subject_repository = subject_repository
        @role = role.to_s
        @resource_scope = resource_scope
        @rules = Array(rules)
        @context = context.to_h.transform_keys(&:to_sym).merge(subject_selectors)
        @arguments = arguments
        @constraints = constraints
        @source = source
        @issued_at = Time.current
        @expires_at = expires_at || (@issued_at + @descriptor.maximum_duration if @descriptor.maximum_duration && duration != :permanent)
        @max_uses = max_uses
        @lifecycle = lifecycle
      end

      def issue!
        validate_descriptor!
        normalized = @descriptor.resource_scope.normalize(@resource_scope, context: @context)
        raise ArgumentError, "resource scope could not be normalized" if normalized.fail_closed?

        candidate = PolicyRule.new(id: "proposed-authority", layer: layer, policy: :allow, source: "authority_grant",
          capability: @descriptor.capability, operation: @descriptor.operation, resource_scope: normalized.value,
          selectors: subject_selectors)
        decision = PolicyEvaluator.new(descriptor: @descriptor, role: @role, resource_scope: normalized.value,
          rules: @rules + [ candidate ], context: @context, arguments: @arguments).call
        raise ArgumentError, "authority exceeds the effective policy ceiling" unless decision.allow?

        persist!(normalized.value)
      end

      private

      def duration = raise NotImplementedError
      def layer = :lease

      def validate_descriptor!
        unless @descriptor.requestable_roles.include?(@role)
          raise ArgumentError, "role is not eligible for this capability"
        end
        unless selector_matches_role?
          raise ArgumentError, "subject selector does not match the requested role"
        end
        raise ArgumentError, "unsupported authority duration: #{duration}" unless @descriptor.authority_durations.include?(duration)
        if AUTONOMY_RANK.fetch(duration) > AUTONOMY_RANK.fetch(@descriptor.maximum_autonomy)
          raise ArgumentError, "authority duration exceeds descriptor maximum autonomy"
        end
        if @descriptor.maximum_duration && @expires_at && @expires_at > @issued_at + @descriptor.maximum_duration
          raise ArgumentError, "authority expiry exceeds descriptor maximum duration"
        end
      end

      def selector_matches_role?
        definition = PermissionRule::SUBJECT_SELECTORS.fetch(@subject_selector_type, {})
        expected_role = definition[:role]
        expected_role ||= @subject_selector_id if definition[:role_from_id]

        expected_role.nil? || expected_role == @role
      end

      def subject_selectors
        { subject_selector_type: @subject_selector_type }.tap do |selectors|
          selectors[:subject_selector_id] = @subject_selector_id if @subject_selector_id.present?
          selectors[:subject_repository_id] = @subject_repository.id if @subject_repository
        end
      end

      def lease_attributes(scope)
        {
          owner_user: @owner, issued_by_user: @actor, subject_selector_type: @subject_selector_type,
          subject_selector_id: @subject_selector_id, subject_repository: @subject_repository,
          capability: @descriptor.capability,
          operation: @descriptor.operation, resource_type: @descriptor.resource_scope.type.to_s,
          resource_scope: scope, constraints: @constraints, effects: @descriptor.effects,
          duration_kind: duration.to_s, source: @source, expires_at: @expires_at, max_uses: @max_uses
        }
      end
    end

    class Invocation < Base
      private

      def duration = :invocation
      def persist!(scope)
        PermissionLease.create!(lease_attributes(scope).merge(max_uses: 1,
          invocation_fingerprint: InvocationFingerprint.call(descriptor: @descriptor, arguments: @arguments)))
      end
    end

    class ChatSessionScope < Base
      private

      def duration = :chat_session
      def persist!(scope) = PermissionLease.create!(lease_attributes(scope).merge(chat_session: @lifecycle.fetch(:chat_session)))
    end

    class JobScope < Base
      private

      def duration = :job
      def persist!(scope) = PermissionLease.create!(lease_attributes(scope).merge(job: @lifecycle.fetch(:job)))
    end

    class Permanent < Base
      def issue!
        raise ArgumentError, "permanent authority cannot expire or have a use limit" if @expires_at || @max_uses

        super
      end

      private

      def duration = :permanent
      def layer = :agent

      def persist!(scope)
        PermissionRule.create!(
          owner_user: @owner, subject_selector_type: @subject_selector_type,
          subject_selector_id: @subject_selector_id, subject_repository: @subject_repository,
          subject_role_keys: [], capability: @descriptor.capability,
          operation: @descriptor.operation, resource_type: @descriptor.resource_scope.type.to_s,
          resource_scope: scope, policy: "allow", constraints: @constraints, policy_layer: "agent",
          source: "operator", provenance: { authority_duration: "permanent" }, created_by_user: @actor,
          updated_by_user: @actor
        )
      end
    end
  end
end
