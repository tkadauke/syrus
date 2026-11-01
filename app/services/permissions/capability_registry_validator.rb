require "digest"

module Permissions
  class CapabilityRegistryValidator
    # Exact per-provider snapshots of compatibility descriptors that predate
    # the explicit descriptor contract. Any addition, removal, or rename
    # changes the digest and makes that provider's legacy definitions fail CI.
    LEGACY_PROVIDER_DIGESTS = {
      [ "agent_insight", "core" ] => "fc25bdc9efec65fb5372dff3cb326b446d9842f7f792b8087c8459a136e30be4",
      [ "chat", "core" ] => "cab9608909ec3875240737865a7b25341fca6e53b52165da73c3ee2c7bc6b14d",
      [ "coworker", "core" ] => "882e4033a321d7ca9876754edeec7d2ebeb1b65bf6cdc2cb7df5a2d3351ad782",
      [ "workflow", "core" ] => "3f9c2913ef3b6f8eb9930524168fe2f5a4e8521ae741876e00932b199b951253",
      [ "chat_mcp_tool_set", "AdminMysql::ChatToolSet" ] => "5c7d6aecd086ecd7618ec2d000b3a5ce820dcbac86782d1b45837e1bf11db4a1",
      [ "chat_mcp_tool_set", "AgentInsights::ChatToolSet" ] => "6d13c3ac7a0448d5834cc72c927596dfb858db1acdb9e1b5bd8f34c89c3aa283",
      [ "chat_mcp_tool_set", "AgentMemory::ChatToolSet" ] => "f73ce2410553e6798a0ff972e51ff288fba2cfb19aca8e90911da63033a913c0",
      [ "chat_mcp_tool_set", "Coworkers::ChatToolSet" ] => "a27790dea57a13c836a117997c4e916c51b79e72e21d37822b5675f93d8048e5",
      [ "chat_mcp_tool_set", "CredentialStore::ChatToolSet" ] => "2ce79bd11d57cf7f3420e8d44cda76a07661752a0c340e51f00b14ce6e4dc94b",
      [ "chat_mcp_tool_set", "DesignDocs::ChatToolSet" ] => "6462de8084132009d25007f0aa27874e3c2180113c97a752097ae27edad09123",
      [ "chat_mcp_tool_set", "K8sCluster::ChatToolSet" ] => "41cc11fbfaf5d60efa73c3db745be4ae7a50a7088f719d6a72843295eeef7ff8",
      [ "chat_mcp_tool_set", "Mockups::ChatToolSet" ] => "92db3b69c34a3f1bde5500df3c50245b36aef5b9447d1fd9002768bb147d53c7",
      [ "chat_mcp_tool_set", "MysqlDbBrowser::ChatToolSet" ] => "15e9374fd401bfb37dda7a83bc8f5168c4124539c8ed67af103347c71a81ac9b",
      [ "chat_mcp_tool_set", "ScheduledTasks::ChatToolSet" ] => "3e073b81df4575e41a5cccf5d37385d32dc7cf5a197a8673c1b08b0e035cca56",
      [ "chat_mcp_tool_set", "SpendingInsights::ChatToolSet" ] => "5d6c20faa36e55244e64275ff9a8c03051eca0370eaac8438ee7d76ad1d9925b",
      [ "chat_mcp_tool_set", "SyrusBrowser::ChatToolSet" ] => "2c63ce82983cf564cca04b287fcb88b0fdd059526a8c66b04eaf3abe47e59875",
      [ "chat_mcp_tool_set", "SyrusDev::ChatToolSet" ] => "61bbaaf46a65d7f996b27826e528a8edd6b7f8fd92bc8910b72e7583e6846f22",
      [ "chat_mcp_tool_set", "TestInsights::ChatToolSet" ] => "da0778212e228e574b97b06e5552e7ea0df1533003094743d5ad96d9e15a23a4",
      [ "chat_mcp_tool_set", "ThemingTools::ChatToolSet" ] => "3635bee4af313a0addc4ddd3b820ce36af226a3c0b061fc2bb722194e8825f05",
      [ "chat_mcp_tool_set", "VideoWalkthroughs::ChatToolSet" ] => "5301c0951ac9646f70a8aa2d92f23723bd580b20a8a81bf6e3c3d9ea62e4fa8a",
      [ "chat_mcp_tool_set", "Whiteboard::ChatToolSet" ] => "a6a099506651a3717bc7d98f887387f93b8ff9b82aad8866699cfcaf25534bbb",
      [ "mcp_tool_set", "AdminMysql::WorkflowToolSet" ] => "e17abbfab94813817e7dd9a698d5ecb48a9576cd67c38ae7f8bb668f9b07b09c",
      [ "mcp_tool_set", "AgentInsights::McpToolSet" ] => "7bdbf574c74236b851d5e29a2011875098f1167c4ae803f1abf62b20352f6694",
      [ "mcp_tool_set", "AgentMemory::McpToolSet" ] => "87d15f9b86f1e8e8d46c65ec06f9c4c3e462d205d1cb0cb7fe0bcbbd8285b784",
      [ "mcp_tool_set", "CognitiveReview::McpToolSet" ] => "87ed553c7f715344aeb0d2c99397dc02ec73bea733c277023dcd515c617db64d",
      [ "mcp_tool_set", "CredentialStore::WorkflowToolSet" ] => "2ce79bd11d57cf7f3420e8d44cda76a07661752a0c340e51f00b14ce6e4dc94b",
      [ "mcp_tool_set", "DesignDocs::WorkflowToolSet" ] => "8c36bd0341a4c9b560099b82fab559364ba6a8cfe9bb28ae95632d1fb03a6556",
      [ "mcp_tool_set", "K8sCluster::WorkflowToolSet" ] => "41cc11fbfaf5d60efa73c3db745be4ae7a50a7088f719d6a72843295eeef7ff8",
      [ "mcp_tool_set", "MysqlDbBrowser::WorkflowToolSet" ] => "15e9374fd401bfb37dda7a83bc8f5168c4124539c8ed67af103347c71a81ac9b",
      [ "mcp_tool_set", "OperatorBriefing::McpToolSet" ] => "7faa47c5163c55fbf0bfab45e19b46b9392c2e01fbf83942d2f0bd6f63a91742",
      [ "mcp_tool_set", "SyrusBrowser::McpToolSet" ] => "2c63ce82983cf564cca04b287fcb88b0fdd059526a8c66b04eaf3abe47e59875",
      [ "mcp_tool_set", "SyrusDev::WorkflowToolSet" ] => "61bbaaf46a65d7f996b27826e528a8edd6b7f8fd92bc8910b72e7583e6846f22",
      [ "mcp_tool_set", "SyrusRails::McpToolSet" ] => "804b2853820cbb52a9da96b61de06f07e1f906e02e739b3758f45b5182c784b3",
      [ "mcp_tool_set", "TestInsights::McpToolSet" ] => "d5ba02fb8ab8455ce58041cdc7f25adc80cf7c7a120dcbb460de83a73840fbaf"
    }.freeze

    Registration = Data.define(:tool_name, :surface, :source, :descriptor, :explicit_descriptor)
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
          descriptor: entry.descriptor, explicit_descriptor: entry.explicit_descriptor
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
      definitions.map do |definition|
        definition = definition.symbolize_keys
        descriptor = CapabilityDescriptorAdapter.for_plugin_definition(definition)
        Registration.new(
          tool_name: definition[:name].to_s,
          surface: extension_point,
          source: provider.name.presence || provider.to_s,
          descriptor: descriptor,
          explicit_descriptor: definition[:capability_descriptor].present?
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
        finding(:missing_descriptor, registration, "has no explicit capability_descriptor")
      end
    end

    def tool_mapping_findings
      registrations.group_by { |registration| [ registration.surface, registration.tool_name ] }.filter_map do |(surface, tool_name), group|
        mappings = group.select(&:explicit_descriptor).filter_map(&:descriptor)
          .map { |descriptor| [ descriptor.capability, descriptor.operation ] }.uniq
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
      registrations.select { |registration| registration.explicit_descriptor && registration.descriptor }
        .group_by { |registration| registration.descriptor.operation }.filter_map do |operation, group|
        contracts = group.group_by { |registration| registration.descriptor.contract_key }
        next if contracts.one?
        Finding.new(
          code: :conflicting_descriptor,
          message: "operation #{operation.inspect} has conflicting descriptor policy/effect contracts from #{group.map(&:source).uniq.sort.join(', ')}",
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

    def legacy_registration_allowed?(registration)
      key = [ registration.surface.to_s, registration.source.to_s ]
      expected_digest = LEGACY_PROVIDER_DIGESTS[key]
      return false unless expected_digest

      legacy_names = registrations.select do |candidate|
        !candidate.explicit_descriptor && [ candidate.surface.to_s, candidate.source.to_s ] == key
      end.map(&:tool_name).sort
      Digest::SHA256.hexdigest(legacy_names.join("\\0")) == expected_digest
    end
  end
end
