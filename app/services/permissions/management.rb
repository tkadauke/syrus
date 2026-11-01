module Permissions
  class Management
    def initialize(user)
      @user = user
    end

    def rules(active: true)
      scope = PermissionRule.for_owner(@user).order(created_at: :desc)
      active ? scope.active : scope
    end

    def leases(active: true)
      scope = PermissionLease.where(owner_user: @user).order(created_at: :desc)
      active ? scope.not_revoked.not_expired.with_uses_remaining : scope
    end

    def descriptor!(payload)
      Catalog.find!(capability: payload.fetch("capability"), operation: payload["operation"])
    end

    def explain(descriptor:, role:, resource_scope:, arguments:, context:)
      LeaseAuthorizer.explain(descriptor:, owner: @user, role:, resource_scope:, arguments:,
        context:, rules: policy_rules).decision
    end

    def grant!(payload, actor:)
      descriptor = descriptor!(payload)
      AuthorityGrant.issue!(
        duration: :permanent, descriptor:, owner: @user, actor:, role: payload.fetch("role"),
        subject_selector_type: payload.fetch("subject_selector_type"),
        subject_selector_id: payload["subject_selector_id"], subject_repository: repository(payload),
        resource_scope: payload.fetch("resource_scope", {}), constraints: payload.fetch("constraints", {}),
        rules: policy_rules
      )
    end

    def deny!(payload, actor:)
      create_rule!(payload, actor:, policy: "deny")
    end

    def ask!(payload, actor:)
      create_rule!(payload, actor:, policy: "ask")
    end

    def create_rule!(payload, actor:, policy:)
      descriptor = descriptor!(payload)
      normalized = descriptor.resource_scope.normalize(payload.fetch("resource_scope", {}), context: {})
      raise ArgumentError, "resource scope could not be normalized" if normalized.fail_closed?

      PermissionRule.create!(rule_attributes(payload, descriptor, normalized.value, actor).merge(policy:))
    end

    def lease!(payload, actor:)
      descriptor = descriptor!(payload)
      duration = payload.fetch("duration").to_sym
      AuthorityGrant.issue!(
        duration:, descriptor:, owner: @user, actor:, role: payload.fetch("role"),
        subject_selector_type: payload.fetch("subject_selector_type"),
        subject_selector_id: payload["subject_selector_id"], subject_repository: repository(payload),
        resource_scope: payload.fetch("resource_scope", {}), constraints: payload.fetch("constraints", {}),
        arguments: payload.fetch("arguments", {}), rules: policy_rules, chat_session: chat_session(payload), job: job(payload),
        expires_at: parse_time(payload["expires_at"]), max_uses: payload["max_uses"]
      )
    end

    def revoke_rule!(id, actor:)
      rules(active: false).find(id).revoke!(actor:)
    end

    def revoke_lease!(id, actor:)
      leases(active: false).find(id).revoke!(actor:)
    end

    def apply_preset!(drafts, actor:)
      drafts = validate_preset_drafts(drafts)
      PermissionRule.transaction do
        drafts.map { |draft| public_send(PRESET_APPLIERS.fetch(draft.fetch("policy")), draft, actor:) }
      end
    end

    def preset_drafts(payload)
      preset = Catalog.presets[payload.fetch("preset").to_s]
      raise ArgumentError, "unknown permission preset" unless preset

      validate_preset_drafts(preset.render(payload))
    end

    def validate_preset_drafts(drafts)
      drafts = Array(drafts)
      raise ArgumentError, "permission preset must render at least one rule" if drafts.empty?

      drafts.map do |draft|
        draft = draft.to_h.stringify_keys
        descriptor = descriptor!(draft)
        raise ArgumentError, "preset capability does not match its operation" unless descriptor.capability == draft.fetch("capability")
        raise ArgumentError, "preset role is not eligible" unless descriptor.requestable_roles.include?(draft.fetch("role"))
        raise ArgumentError, "unknown permission preset policy" unless PRESET_APPLIERS.key?(draft.fetch("policy"))

        draft
      end
    end

    private :create_rule!, :validate_preset_drafts

    private

    PRESET_APPLIERS = { "allow" => :grant!, "ask" => :ask!, "deny" => :deny! }.freeze

    def policy_rules = rules.map(&:to_policy_rule)

    def repository(payload)
      return unless payload["subject_repository_id"].present?

      scope = @user.admin? ? Repository.active : Repository.accessible_to(@user).active
      scope.find(payload["subject_repository_id"])
    end

    def chat_session(payload)
      return unless payload["chat_session_id"].present?

      @user.chat_sessions.find(payload["chat_session_id"])
    end

    def job(payload)
      return unless payload["job_id"].present?

      Job.visible_to(@user, scope: @user.admin? ? Job.all : @user.jobs).find(payload["job_id"])
    end

    def parse_time(value)
      Time.iso8601(value) if value.present?
    end

    def rule_attributes(payload, descriptor, scope, actor)
      {
        owner_user: @user, created_by_user: actor, updated_by_user: actor,
        subject_selector_type: payload.fetch("subject_selector_type"),
        subject_selector_id: payload["subject_selector_id"], subject_repository: repository(payload),
        subject_role_keys: payload.fetch("subject_role_keys", []), dynamic_future_roles: payload.fetch("dynamic_future_roles", false),
        capability: descriptor.capability, operation: descriptor.operation,
        resource_type: descriptor.resource_scope.type.to_s, resource_scope: scope,
        constraints: payload.fetch("constraints", {}), policy_layer: "agent", source: "operator",
        provenance: { "management_api" => true }, rationale: payload["rationale"], delegable: true
      }
    end
  end
end
