module Coworkers
  # Auditable view of the default policy every coworker tool gets, grouped into
  # allow/ask/deny with a reason, plus the invariants that stop a new tool from
  # silently inheriting an unsafe or contradictory default:
  #
  # * a coworker role may only default to +allow+ when the descriptor's
  #   classified effects and risk are fully benign
  #   (Permissions::CoworkerDefaultPolicy);
  # * the advertised grant default (+default_policy+) must agree with the
  #   effective descriptor default of every gated tool the grant covers;
  # * every coworker role must receive the same default.
  #
  # Reasons are audit data, not end-user copy.
  class ToolDefaultPolicyReport
    GRANT_POLICIES = { "auto" => :allow, "confirm" => :ask, "queue" => :ask, "off" => :deny }.freeze
    ROLES = Permissions::CoworkerDefaultPolicy::ROLES

    Row = Data.define(:tool, :source, :tier, :grant, :grant_default, :capability, :operation, :effects, :risk,
      :resource_scope, :maximum_autonomy, :ungated, :availability, :default, :reason) do
      def to_h = super.merge(effects: effects.map(&:to_s), risk: risk.to_s, default: default.to_s, availability: availability.to_s)
    end

    def initialize(chat_session: nil, catalog: Mcp::CoworkerToolCatalog.all(chat_session: chat_session),
      grants: Coworkers::GrantCatalog.all)
      @catalog = catalog
      @grants = grants
    end

    def rows
      @rows ||= catalog.filter_map { |entry| row_for(entry) }.sort_by { |row| [ row.default.to_s, row.capability.to_s, row.tool ] }
    end

    # { allow: [rows], ask: [rows], deny: [rows] }
    def grouped
      Permissions::CapabilityDescriptor::POLICIES.reverse.index_with { |policy| rows.select { |row| row.default == policy } }
    end

    def findings
      @findings ||= descriptor_findings + role_findings + grant_findings
    end

    def validate!
      raise ArgumentError, "Coworker default policy invariants failed:\n- #{findings.join("\n- ")}" if findings.any?

      true
    end

    def as_json(*)
      { groups: grouped.transform_values { |group| group.map(&:to_h) }, findings: findings }
    end

    def to_text
      grouped.flat_map do |policy, group|
        [ "#{policy.to_s.upcase} (#{group.length})" ] + group.map do |row|
          "  #{row.tool.ljust(34)} #{row.capability.to_s.ljust(26)} #{row.risk.to_s.ljust(7)} #{row.effects.join(',')} -- #{row.reason}"
        end
      end.join("\n")
    end

    private

    attr_reader :catalog, :grants

    def descriptors
      @descriptors ||= catalog.filter_map do |entry|
        descriptor = descriptor_for(entry)
        [ entry, descriptor ] if descriptor
      end
    end

    def descriptor_for(entry)
      if entry.tool
        McpToolRegistry.entries(surface: :coworker).find { |candidate| candidate.tool == entry.tool }&.descriptor
      elsif entry.definition
        Permissions::CapabilityDescriptorAdapter.for_plugin_definition(entry.definition)
      end
    end

    def row_for(entry)
      descriptor = descriptor_for(entry)
      return unless descriptor

      verdict = Permissions::CoworkerDefaultPolicy.verdict(descriptor)
      grant = grants.find { |candidate| candidate.tools.include?(entry.tool_name) }
      Row.new(tool: entry.tool_name, source: entry.provider&.name || "core", tier: entry.tier,
        grant: grant&.name || entry.capability, grant_default: grant&.default_policy,
        capability: descriptor.capability, operation: descriptor.operation, effects: descriptor.effects, risk: descriptor.risk,
        resource_scope: descriptor.resource_scope.type, maximum_autonomy: descriptor.maximum_autonomy,
        ungated: entry.ungated, availability: entry.availability_state, default: verdict.policy, reason: verdict.reason)
    end

    def descriptor_findings
      descriptors.flat_map { |entry, descriptor| Permissions::CoworkerDefaultPolicy.violations(descriptor).map { |message| "#{entry.tool_name}: #{message}" } }
    end

    def role_findings
      descriptors.filter_map do |entry, descriptor|
        policies = ROLES.filter_map { |role| descriptor.defaults[role] if descriptor.requestable_roles.include?(role) }
        next if policies.uniq.length <= 1

        "#{entry.tool_name}: coworker roles disagree on the default policy (#{policies.uniq.join(', ')})"
      end
    end

    def grant_findings
      by_name = descriptors.to_h { |entry, descriptor| [ entry.tool_name, [ entry, descriptor ] ] }
      grants.flat_map do |grant|
        advertised = GRANT_POLICIES[grant.default_policy.to_s]
        grant.tools.filter_map do |tool_name|
          entry, descriptor = by_name[tool_name]
          next unless descriptor && !entry.ungated && Permissions::CoworkerDefaultPolicy.requestable?(descriptor)

          effective = Permissions::CoworkerDefaultPolicy.verdict(descriptor).policy
          next if effective == advertised

          "#{tool_name}: grant #{grant.name} advertises #{grant.default_policy} (#{advertised.inspect}) but the descriptor's effective default is #{effective}"
        end
      end
    end
  end
end
