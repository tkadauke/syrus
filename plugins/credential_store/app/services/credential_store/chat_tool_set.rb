module CredentialStore
  class ChatToolSet
    include Syrus::Plugin::ChatMcpToolSet

    TOOL_CLASSES = [ ListCredentialsTool, SshExecTool ].freeze

    def self.available_for?(chat_session, tier:)
      CredentialStore.enabled? && chat_session.present? && tier.to_sym == :deferred
    end

    def self.tool_definitions(tier:)
      return [] unless tier.nil? || tier.to_sym == :deferred

      TOOL_CLASSES.map do |klass|
        definition = {
          name: klass.tool_name,
          description: klass.description_value,
          input_schema: klass.input_schema_value.to_h
        }
        definition[:capability_descriptor] = klass.capability_descriptor_value if klass.respond_to?(:capability_descriptor_value)
        definition
      end
    end

    def handle(tool_name, params, server_context)
      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return Mcp::Tools.invalid("Unknown credential store tool: #{tool_name.inspect}") unless klass

      klass.call(**symbolize(params), server_context: server_context)
    end

    private

    def symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
