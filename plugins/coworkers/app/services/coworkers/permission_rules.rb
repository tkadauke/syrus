module Coworkers
  # Canonical permission-rule projection for one coworker. The old grant
  # catalog remains presentation metadata; authority lives only in rules.
  class PermissionRules
    POLICY = { "auto" => "allow", "confirm" => "ask", "queue" => "ask" }.freeze
    LEGACY_POLICY = { "allow" => "auto", "ask" => "confirm", "deny" => "off" }.freeze

    def initialize(coworker)
      @coworker = coworker
    end

    def rules(active: true)
      relation = PermissionRule.where(
        owner_user: coworker.owner_user, subject_selector_type: "agent",
        subject_selector_id: coworker.id.to_s
      )
      active ? relation.active : relation
    end

    def entries
      Coworkers::GrantCatalog.all.map do |descriptor|
        matching = rules.select { |rule| unversioned(rule.capability) == descriptor.name }
        policy = matching.map(&:policy).min_by { |value| policy_rank(value) }
        source = matching.first
        {
          capability: descriptor.name,
          approval_policy: LEGACY_POLICY.fetch(policy, "off"),
          constraints: source&.constraints || {}
        }.tap do |entry|
          scope = legacy_scope(matching.map(&:resource_scope), descriptor:)
          entry[:scope] = scope unless scope.nil?
        end
      end
    end

    def update!(capability:, approval_policy:, constraints: {}, scope: nil, actor:, provenance: {}, source: "coworker_permission")
      descriptors = canonical_descriptors(capability)
      raise ArgumentError, "no canonical permission descriptors for #{capability}" if descriptors.empty?

      PermissionRule.transaction do
        rules.where(capability: descriptors.map(&:capability)).find_each { |rule| rule.revoke!(actor:) }
        return nil if approval_policy.to_s == "off"

        policy = POLICY.fetch(approval_policy.to_s)
        descriptors.flat_map do |descriptor|
          scopes_for(descriptor, scope).map do |resource_scope|
            PermissionRule.create!(
              owner_user: coworker.owner_user, created_by_user: actor, updated_by_user: actor,
              subject_selector_type: "agent", subject_selector_id: coworker.id.to_s,
              subject_role_keys: [], dynamic_future_roles: false,
              capability: descriptor.capability, operation: descriptor.operation,
              resource_type: descriptor.resource_scope.type.to_s, resource_scope: resource_scope,
              constraints: constraints.to_h, policy:, policy_layer: "agent", source:,
              provenance: { "coworker_id" => coworker.id }.merge(provenance.stringify_keys),
              rationale: "Coworker permission configured by the owner", delegable: false
            )
          end
        end
      end
    end

    private

    attr_reader :coworker

    def canonical_descriptors(capability)
      registered = Permissions::CapabilityRegistryValidator.for_application.registrations.filter_map do |registration|
        descriptor = registration.descriptor
        descriptor if descriptor && unversioned(descriptor.capability) == capability.to_s
      end
      catalog = Mcp::CoworkerToolCatalog.all.filter_map do |tool|
        next unless tool.capability.to_s == capability.to_s

        if tool.tool
          entry = McpToolRegistry.entry_for(tool.tool)
          entry&.descriptor || (entry && Permissions::CapabilityDescriptorAdapter.for_registry_entry(
            tool_name: entry.tool_name, capability: entry.capability, mutation: entry.mutation,
            required_roles: entry.required_roles, admin_only: entry.admin_only
          ))
        elsif tool.definition
          Permissions::CapabilityDescriptorAdapter.for_plugin_definition(tool.definition)
        end
      end
      descriptors = (registered + catalog).uniq { |descriptor| [ descriptor.capability, descriptor.operation ] }
      return descriptors if descriptors.any?

      grant = Coworkers::GrantCatalog.fetch(capability)
      [ Permissions::CapabilityDescriptorAdapter.for_registry_entry(
        tool_name: "#{capability}.access", capability:, mutation: grant.default_policy != "auto",
        required_roles: [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ],
        default_policy: POLICY.fetch(grant.default_policy).to_sym
      ) ]
    end

    def scopes_for(descriptor, legacy_scope)
      candidates = if legacy_scope.is_a?(Hash)
        [ legacy_scope ]
      elsif legacy_scope.present?
        key = scope_key(descriptor)
        key ? Array(legacy_scope).map { |value| { key => value } } : [ {} ]
      else
        [ {} ]
      end
      candidates.map do |candidate|
        normalized = descriptor.resource_scope.normalize(candidate, context: {})
        raise ArgumentError, "invalid resource scope for #{descriptor.operation}" if normalized.fail_closed?
        normalized.value
      end.uniq
    end

    def scope_key(descriptor)
      options = descriptor.resource_scope.to_h.fetch(:options, {}).to_h
      (Array(options[:hierarchy]).first || Array(options[:required]).first)&.to_s
    end

    def legacy_scope(scopes, descriptor:)
      values = scopes.reject(&:blank?)
      if descriptor.scopeable? && values.one? && values.first.is_a?(Hash) && values.first.one?
        return values.first.values.first
      end
      values.one? ? values.first : values.presence
    end

    def unversioned(value) = value.to_s.sub(/@v\d+\z/, "")
    def policy_rank(value) = Permissions::PolicyEvaluator::POLICY_RANK.fetch(value.to_sym)
  end
end
