module Mcp
  class CoworkerToolCatalog
    Descriptor = Data.define(:tool_name, :capability, :ungated, :tier, :tool, :provider)

    class << self
      def resolve(tool_or_name, chat_session: nil)
        name = tool_or_name.is_a?(String) || tool_or_name.is_a?(Symbol) ? tool_or_name.to_s : McpToolRegistry.tool_name_for(tool_or_name)
        core_descriptors.find { |descriptor| descriptor.tool == tool_or_name || descriptor.tool_name == name } ||
          plugin_descriptors(chat_session: chat_session).find { |descriptor| descriptor.tool_name == name }
      end

      def all = core_descriptors + plugin_descriptors

      private

      def core_descriptors
        McpToolRegistry.entries(surface: :coworker).map do |entry|
          Descriptor.new(tool_name: entry.tool_name, capability: entry.capability&.to_s, ungated: entry.ungated,
            tier: entry.tier, tool: entry.tool, provider: nil)
        end
      end

      def plugin_descriptors(chat_session: nil)
        Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set).flat_map do |provider|
          definitions_for(provider, chat_session: chat_session).filter_map do |definition|
            next unless value(definition, :coworker_safe) == true

            name = value(definition, :name).to_s
            capability = value(definition, :capability)&.to_s
            ungated = value(definition, :ungated) == true
            unless ungated || grant_tools(provider).fetch(capability, []).include?(name)
              raise ArgumentError, "coworker tool #{name.inspect} has no resolvable grant and is not ungated"
            end

            Descriptor.new(tool_name: name, capability: capability, ungated: ungated,
              tier: definition_tier(provider, name, chat_session: chat_session), tool: nil, provider: provider)
          end
        end
      end

      def definitions_for(provider, chat_session: nil)
        parameters = provider.method(:tool_definitions).parameters
        accepts_chat = parameters.any? { |type, name| [ :key, :keyreq ].include?(type) && name == :chat_session }
        return provider.tool_definitions(tier: nil) unless chat_session && accepts_chat

        %i[essential deferred].flat_map { |tier| provider.tool_definitions(tier: tier, chat_session: chat_session) }
      rescue ArgumentError
        []
      end

      def definition_tier(provider, name, chat_session: nil)
        parameters = provider.method(:tool_definitions).parameters
        accepts_chat = parameters.any? { |type, parameter_name| [ :key, :keyreq ].include?(type) && parameter_name == :chat_session }
        %i[essential deferred].find do |tier|
          keywords = { tier: tier }
          keywords[:chat_session] = chat_session if accepts_chat
          Array(provider.tool_definitions(**keywords)).any? { |definition| value(definition, :name).to_s == name }
        end || :essential
      end

      def grant_tools(provider)
        Array(provider.respond_to?(:coworker_grants) ? provider.coworker_grants : []).each_with_object({}) do |grant, tools|
          attributes = grant.to_h.stringify_keys
          tools[attributes.fetch("name").to_s] = Array(attributes["tools"]).map(&:to_s)
        end
      end

      def value(definition, key) = definition[key] || definition[key.to_s]
    end
  end
end
