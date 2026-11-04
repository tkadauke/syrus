require "digest"

module SyrusDev
  class PermissionFactoryReset
    DEFAULT_VERSION = "permissions-factory@v1"
    DEFAULT_PROFILE = "ask_on_first_use@v1"
    # Resource-specific presets require a connection or credential selection;
    # the first factory version intentionally has no unscoped preset drafts.
    DEFAULT_PRESETS = [].freeze
    PROFILE_SUBJECTS = %w[interactive_chat coding_chat local_chat].freeze
    RESET_REASON = "permission_factory_reset"

    Preview = Data.define(:scope_type, :scope_id, :default_version, :counts, :confirmation_digest) do
      def to_h = { scope_type:, scope_id:, default_version:, counts:, confirmation_digest: }
    end

    Result = Data.define(:record, :counts, :changed) do
      def changed? = changed
    end

    def initialize(scope_type:, scope_id: nil, initiated_by:)
      raise ArgumentError, "syrus_dev plugin is disabled" unless PluginRecord.find_by(name: "syrus_dev")&.effective_enabled?
      raise ArgumentError, "initiating user must be an admin" unless initiated_by&.admin?

      @scope = PermissionFactoryResetScope.for(scope_type, id: scope_id)
      @initiated_by = initiated_by
    end

    def preview
      counts = preview_counts
      Preview.new(
        scope_type: scope.key,
        scope_id: scope.id,
        default_version: DEFAULT_VERSION,
        counts:,
        confirmation_digest: digest(counts)
      )
    end

    def confirm!(confirmation_digest:)
      audit = ::SyrusDev::PermissionFactoryResetRecord.create!(
        initiated_by_user: initiated_by,
        scope_type: scope.key,
        scope_id: scope.id,
        default_version: DEFAULT_VERSION,
        outcome: "started",
        counts: {}
      )

      counts = nil
      ApplicationRecord.transaction do
        counts = preview_counts(lock: true)
        raise ArgumentError, "permission reset preview is stale" unless secure_digest_match?(confirmation_digest, digest(counts))

        revoke_rules!
        revoke_leases!
        invalidate_invocations!
        cancel_requests!
        apply_factory_profiles!
      end
      audit.update!(outcome: "succeeded", counts:, completed_at: Time.current)
      Result.new(record: audit, counts:, changed: counts.values.sum.positive?)
    rescue StandardError => error
      record_failed_audit(audit, counts, error)
      raise
    end

    private

    attr_reader :scope, :initiated_by

    def preview_counts(lock: false)
      relations = affected_relations
      relations.transform_values! { |relation| relation.lock.load } if lock
      {
        "rules" => relations.fetch(:rules).size,
        "leases" => relations.fetch(:leases).size,
        "authorized_invocations" => relations.fetch(:invocations).size,
        "pending_requests" => relations.fetch(:requests).size,
        "resumptions" => relations.fetch(:resumptions).size,
        "profile_selections" => relations.fetch(:profiles).size,
        "factory_rules_to_create" => factory_rules_to_create_count,
        "factory_presets_to_create" => DEFAULT_PRESETS.size
      }.freeze
    end

    def affected_relations
      active_rules = scope.rules.active
      resettable_rules = active_rules.where.not(source: factory_source)
      leases = scope.leases.not_revoked
      requests = scope.requests.where(state: %w[queued pending])
      invocations = AuthorizedInvocation.unclaimed.where(
        "authority_type = 'PermissionRule' AND authority_id IN (?) OR authority_type = 'PermissionLease' AND authority_id IN (?) OR pending_action_item_id IN (?)",
        active_rules.select(:id), leases.select(:id), requests.joins(:authorization_items).select("pending_action_items.id")
      )
      {
        rules: resettable_rules,
        leases:,
        invocations:,
        requests:,
        resumptions: requests.where(checkpoint_state: ChatPendingAction::NONTERMINAL_CHECKPOINT_STATES),
        profiles: active_rules.where("source LIKE ?", "#{Permissions::Management::PROFILE_SOURCE_PREFIX}%").where.not(source: factory_source)
      }
    end

    def revoke_rules!
      affected_relations.fetch(:rules).find_each { |rule| rule.revoke!(actor: initiated_by) }
    end

    def revoke_leases!
      affected_relations.fetch(:leases).find_each { |lease| lease.revoke!(actor: initiated_by) }
    end

    def invalidate_invocations!
      # Rule and lease revocation invalidates their tokens. This pass also
      # catches tokens attached directly to affected authorization requests.
      affected_relations.fetch(:invocations).find_each { |invocation| invocation.invalidate!(RESET_REASON) }
    end

    def cancel_requests!
      affected_relations.fetch(:requests).find_each do |request|
        request.authorization_items.pending.find_each { |item| item.mark_non_actionable!(RESET_REASON) }
        request.cancel!(user: request.user)
      end
    end

    def apply_factory_profiles!
      profile = Permissions::PermissionProfiles.fetch(DEFAULT_PROFILE)
      scope.profile_users.find_each do |user|
        management = Permissions::Management.new(user)
        PROFILE_SUBJECTS.each do |subject|
          next if profile_will_be_current?(management, subject)

          plan = management.profile_plan(profile_key: DEFAULT_PROFILE, subject_selector_type: subject, lock: true)
          management.apply_profile!(plan:, actor: initiated_by)
        end
      end
    end

    def factory_rules_to_create_count
      scope.profile_users.sum do |user|
        management = Permissions::Management.new(user)
        PROFILE_SUBJECTS.sum do |subject|
          next 0 if profile_will_be_current?(management, subject)

          management.profile_plan(profile_key: DEFAULT_PROFILE, subject_selector_type: subject).fetch(:replacements).size
        end
      end
    end

    def profile_will_be_current?(management, subject)
      plan = management.profile_plan(profile_key: DEFAULT_PROFILE, subject_selector_type: subject)
      actual = management.rules.where(subject_selector_type: subject).map { |rule| profile_rule_signature(rule) }
      expected = plan.fetch(:replacements).map do |replacement|
        descriptor = replacement.fetch(:descriptor)
        {
          capability: descriptor.capability,
          operation: descriptor.operation,
          resource_type: descriptor.resource_scope.type.to_s,
          resource_scope: {},
          constraints: {},
          policy: replacement.fetch(:policy).to_s,
          policy_layer: "agent",
          source: factory_source,
          subject_selector_id: nil,
          subject_repository_id: nil,
          subject_role_keys: [],
          dynamic_future_roles: false,
          delegable: true
        }
      end
      actual.sort_by(&:to_json) == expected.sort_by(&:to_json)
    end

    def profile_rule_signature(rule)
      {
        capability: rule.capability,
        operation: rule.operation,
        resource_type: rule.resource_type,
        resource_scope: rule.resource_scope,
        constraints: rule.constraints,
        policy: rule.policy,
        policy_layer: rule.policy_layer,
        source: rule.source,
        subject_selector_id: rule.subject_selector_id,
        subject_repository_id: rule.subject_repository_id,
        subject_role_keys: rule.subject_role_keys,
        dynamic_future_roles: rule.dynamic_future_roles,
        delegable: rule.delegable
      }
    end

    def record_failed_audit(audit, counts, error)
      audit&.update!(
        outcome: "failed",
        counts: counts || {},
        error_message: "#{error.class}: #{error.message}",
        completed_at: Time.current
      )
    rescue StandardError => audit_error
      Rails.logger.error(
        "Permission factory reset failure audit could not be completed: " \
          "#{audit_error.class}: #{audit_error.message}"
      )
    end

    def factory_source = "#{Permissions::Management::PROFILE_SOURCE_PREFIX}#{DEFAULT_PROFILE}"

    def digest(counts)
      Digest::SHA256.hexdigest([ scope.key, scope.id, DEFAULT_VERSION, counts.sort ].to_json)
    end

    def secure_digest_match?(provided, expected)
      provided.present? && provided.bytesize == expected.bytesize && ActiveSupport::SecurityUtils.secure_compare(provided, expected)
    end
  end
end
