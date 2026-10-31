require "mcp"

module SyrusDev
  class ChatToolSet
    include Syrus::Plugin::ChatMcpToolSet

    CAPABILITY = "syrus_dev.read_diagnostics"
    TOOL_CLASSES = [ ReadPerformanceDiagnosticsTool, ReadSyrusLogsTool ].freeze

    def self.coworker_grants
      [
        {
          name: CAPABILITY,
          label: "Read Syrus diagnostics",
          description: "Read sanitized Syrus performance diagnostics and operational logs.",
          default_policy: "confirm",
          maximum_policy: "auto",
          tools: TOOL_CLASSES.map(&:tool_name),
          scope_options_callback: nil,
          scope_label_callback: nil,
          valid_scope_callback: nil
        }
      ]
    end

    def self.available_for?(_chat_session, tier:) = false

    def self.available_for_coworker?(_chat_session, tier:)
      SyrusDev.enabled? && tier.to_sym == :essential
    end

    def self.tool_definitions(tier:)
      return TOOL_CLASSES.map { |klass| definition_for(klass) } if tier.nil?
      return [] unless tier.to_sym == :essential

      TOOL_CLASSES.map { |klass| definition_for(klass) }
    end

    def self.definition_for(klass)
      {
        name: klass.tool_name,
        description: klass.description_value,
        input_schema: klass.input_schema_value.to_h,
        coworker_safe: true,
        capability: CAPABILITY
      }
    end

    def handle(tool_name, params, server_context)
      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return MCP::Tool::Response.new([ { type: "text", text: "Unknown Syrus Dev tool: #{tool_name.inspect}" } ], error: true) unless klass

      klass.call(**symbolize(params), server_context: server_context)
    rescue StandardError => e
      Rails.logger.error("[SyrusDev::ChatToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    private

    def symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
