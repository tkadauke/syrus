require "digest"

module Permissions
  class CapabilityRegistryValidator
    COMPATIBILITY_DIGEST_PATTERN = /\A[0-9a-f]{64}\z/

    Registration = Data.define(:tool_name, :surface, :source, :descriptor, :explicit_descriptor, :compatibility_descriptor)
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
        Registration.new(
          tool_name: entry.tool_name, surface: entry.surface, source: "core",
          descriptor: entry.descriptor, explicit_descriptor: entry.explicit_descriptor,
          compatibility_descriptor: entry.compatibility_descriptor?
        )
      end
      plugin = %i[mcp_tool_set chat_mcp_tool_set].flat_map do |extension_point|
        Syrus::PluginRegistry.providers_for(extension_point).flat_map do |provider|
          plugin_registrations(provider, extension_point)
        end
      end
      permission_providers = Syrus::PluginRegistry.providers_for(:permission_provider).flat_map do |provider|
        provider.permission_capability_descriptors.map do |descriptor|
          Registration.new(
            tool_name: descriptor.operation, surface: :permission_provider,
            source: provider.name.presence || provider.to_s,
            descriptor: descriptor, explicit_descriptor: true
          )
        end
      end
      new(core + plugin + permission_providers)
    end

    def self.plugin_registrations(provider, extension_point)
      definitions = Syrus::PluginRegistry.all_tool_definitions(provider)
      compatibility_digest = plugin_compatibility_digest(provider, extension_point)
      definitions.map do |definition|
        definition = definition.symbolize_keys
        descriptor = CapabilityDescriptorAdapter.for_plugin_definition(definition)
        Registration.new(
          tool_name: definition[:name].to_s,
          surface: extension_point,
          source: provider.name.presence || provider.to_s,
          descriptor: descriptor,
          explicit_descriptor: definition[:capability_descriptor].present?,
          compatibility_descriptor: compatibility_digest
        )
      end
    end
    private_class_method :plugin_registrations

    def self.plugin_compatibility_digest(provider, extension_point)
      manifest = Syrus::PluginRegistry.all_plugins.find do |candidate|
        Array(candidate.provides[extension_point]).include?(provider)
      end
      digest = manifest&.metadata&.dig(:capability_descriptor_compatibility, extension_point)
      digest if digest.is_a?(String) && digest.match?(COMPATIBILITY_DIGEST_PATTERN)
    end
    private_class_method :plugin_compatibility_digest

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
      explicit_descriptors = registrations.count { |registration| registration.descriptor && registration.explicit_descriptor }
      roles = descriptors.flat_map(&:requestable_roles).uniq.sort
      effects = CapabilityDescriptor::EFFECTS.index_with { 0 }
      descriptors.each { |descriptor| descriptor.effects.each { |effect| effects[effect] += 1 } }

      {
        tools: registrations.length,
        described_tools: descriptors.length,
        explicit_descriptors: explicit_descriptors,
        legacy_descriptors: descriptors.length - explicit_descriptors,
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
        next if registration.descriptor && (registration.explicit_descriptor || legacy_registration_allowed?(registration))
        finding(:missing_descriptor, registration,
          I18n.t("server.permissions.capability_registry.missing_descriptor_detail"))
      end
    end

    def tool_mapping_findings
      registrations.group_by { |registration| [ registration.surface, registration.tool_name ] }.filter_map do |(surface, tool_name), group|
        mappings = group.select(&:explicit_descriptor).filter_map(&:descriptor)
          .map { |descriptor| [ descriptor.capability, descriptor.operation ] }.uniq
        next if mappings.length <= 1
        Finding.new(
          code: :conflicting_tool_mapping,
          message: I18n.t("server.permissions.capability_registry.conflicting_tool_mapping",
            surface:, tool_name: tool_name.inspect, mappings: mappings.inspect),
          registrations: group
        )
      end
    end

    def identifier_findings
      canonical_and_alias_findings(:capability) + canonical_and_alias_findings(:operation)
    end

    def descriptor_conflict_findings
      registrations.select { |registration| registration.explicit_descriptor && registration.descriptor }
        .group_by { |registration| registration.descriptor.operation }.filter_map do |operation, group|
        contracts = group.group_by { |registration| registration.descriptor.contract_key }
        next if contracts.one?
        Finding.new(
          code: :conflicting_descriptor,
          message: I18n.t("server.permissions.capability_registry.conflicting_descriptor",
            operation: operation.inspect, sources: group.map(&:source).uniq.sort.join(", ")),
          registrations: group
        )
      end
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
          message: I18n.t("server.permissions.capability_registry.conflicting_identifier",
            kind:, identifier: identifier.inspect, targets: canonical_targets.inspect),
          registrations: involved
        )
      end
    end

    def finding(code, registration, detail)
      Finding.new(
        code: code,
        message: I18n.t("server.permissions.capability_registry.registration_finding",
          source: registration.source, surface: registration.surface,
          tool_name: registration.tool_name.inspect, detail:),
        registrations: [ registration ]
      )
    end

    def legacy_registration_allowed?(registration)
      expected_digest = registration.compatibility_descriptor
      return false unless expected_digest
      return true if expected_digest == true

      legacy_names = registrations.select do |candidate|
        !candidate.explicit_descriptor && candidate.surface == registration.surface && candidate.source == registration.source
      end.map(&:tool_name).sort
      Digest::SHA256.hexdigest(legacy_names.join("\\0")) == expected_digest
    end
  end
end
