module Permissions
  class CapabilityRegistryValidator
    Registration = Data.define(:tool_name, :surface, :source, :descriptor)
    Finding = Data.define(:code, :message, :registrations) do
      def to_h = { code: code, message: message, registrations: registrations }
    end

    class ValidationError < StandardError
      attr_reader :findings

      def initialize(findings)
        @findings = findings
        super("Capability registry validation failed:\n- #{findings.map(&:message).join("\n- ")}")
      end
    end

    attr_reader :registrations

    def self.for_application
      core = McpToolRegistry.entries.map do |entry|
        Registration.new(tool_name: entry.tool_name, surface: entry.surface, source: "core", descriptor: entry.descriptor)
      end
      plugin = %i[mcp_tool_set chat_mcp_tool_set].flat_map do |extension_point|
        Syrus::PluginRegistry.providers_for(extension_point).flat_map do |provider|
          plugin_registrations(provider, extension_point)
        end
      end
      new(core + plugin)
    end

    def self.plugin_registrations(provider, extension_point)
      definitions = Syrus::PluginRegistry.send(:safe_tool_definitions, provider)
      definitions.map do |definition|
        definition = definition.symbolize_keys
        descriptor = CapabilityDescriptorAdapter.for_plugin_definition(definition)
        Registration.new(
          tool_name: definition[:name].to_s,
          surface: extension_point,
          source: provider.name.presence || provider.to_s,
          descriptor: descriptor
        )
      end
    end
    private_class_method :plugin_registrations

    def initialize(registrations)
      @registrations = registrations
    end

    def validate!
      current_findings = findings
      raise ValidationError, current_findings if current_findings.any?
      true
    end

    def findings
      missing_descriptor_findings + tool_mapping_findings + descriptor_conflict_findings + identifier_findings
    end

    def coverage
      descriptors = registrations.filter_map(&:descriptor)
      roles = descriptors.flat_map(&:requestable_roles).uniq.sort
      effects = CapabilityDescriptor::EFFECTS.index_with { 0 }
      descriptors.each { |descriptor| descriptor.effects.each { |effect| effects[effect] += 1 } }

      {
        tools: registrations.length,
        described_tools: descriptors.length,
        roles: roles.index_with do |role|
          role_descriptors = descriptors.select { |descriptor| descriptor.requestable_roles.include?(role) }
          { descriptors: role_descriptors.length, defaults: role_descriptors.map { |descriptor| descriptor.defaults.fetch(role) }.tally }
        end,
        effects: effects
      }
    end

    private

    def missing_descriptor_findings
      registrations.filter_map do |registration|
        next if registration.descriptor
        finding(:missing_descriptor, registration, "has no explicit capability_descriptor")
      end
    end

    def tool_mapping_findings
      registrations.group_by { |registration| [ registration.surface, registration.tool_name ] }.filter_map do |(surface, tool_name), group|
        mappings = group.filter_map(&:descriptor).map { |descriptor| [ descriptor.capability, descriptor.operation ] }.uniq
        next if mappings.length <= 1
        Finding.new(
          code: :conflicting_tool_mapping,
          message: "#{surface} tool #{tool_name.inspect} maps to conflicting capability/operations #{mappings.inspect}; use one stable mapping",
          registrations: group
        )
      end
    end

    def identifier_findings
      canonical_and_alias_findings(:capability) + canonical_and_alias_findings(:operation)
    end

    def descriptor_conflict_findings
      registrations.select(&:descriptor).group_by { |registration| registration.descriptor.operation }.filter_map do |operation, group|
        contracts = group.group_by { |registration| descriptor_contract(registration.descriptor) }
        next if contracts.one?
        Finding.new(
          code: :conflicting_descriptor,
          message: "operation #{operation.inspect} has conflicting descriptor policy/effect contracts from #{group.map(&:source).uniq.sort.join(', ')}",
          registrations: group
        )
      end
    end

    def descriptor_contract(descriptor)
      [
        descriptor.capability, descriptor.effects.sort, descriptor.risk,
        descriptor.maximum_autonomy, descriptor.authority_durations.sort,
        descriptor.maximum_duration, descriptor.resource_scope.type,
        descriptor.capability_aliases.sort, descriptor.operation_aliases.sort
      ]
    end

    def canonical_and_alias_findings(kind)
      canonical_method = kind
      aliases_method = :"#{kind}_aliases"
      claims = Hash.new { |hash, key| hash[key] = [] }
      registrations.each do |registration|
        next unless registration.descriptor
        canonical = registration.descriptor.public_send(canonical_method)
        claims[canonical] << [ canonical, registration ]
        registration.descriptor.public_send(aliases_method).each { |identifier| claims[identifier] << [ canonical, registration ] }
      end
      claims.filter_map do |identifier, entries|
        canonical_targets = entries.map(&:first).uniq
        next if canonical_targets.one?
        involved = entries.map(&:last).uniq
        Finding.new(
          code: :conflicting_identifier,
          message: "#{kind} identifier #{identifier.inspect} is claimed by #{canonical_targets.inspect}; aliases must resolve to exactly one canonical identifier",
          registrations: involved
        )
      end
    end

    def finding(code, registration, detail)
      Finding.new(
        code: code,
        message: "#{registration.source} #{registration.surface} tool #{registration.tool_name.inspect} #{detail}",
        registrations: [ registration ]
      )
    end
  end
end
