module Syrus
  class PluginRegistry
    EXTENSION_POINTS = %i[agent_provider mcp_tool_set input_source].freeze

    # Lambdas defer constant resolution until call time (autoload-friendly).
    INTERFACE_FOR = {
      agent_provider: -> { Syrus::Plugin::AgentProvider },
      mcp_tool_set:   -> { Syrus::Plugin::McpToolSet },
      input_source:   -> { Syrus::Plugin::InputSource }
    }.freeze

    RegistrationError = Class.new(StandardError)

    @mutex   = Mutex.new
    @plugins = []

    class << self
      # Called by each plugin's engine initializer before the app handles requests.
      def register(name:, version:, provides: {}, **metadata)
        validate_provides!(provides)

        @mutex.synchronize do
          validate_mcp_tool_name_uniqueness!(provides)
          @plugins << Syrus::Plugin::Manifest.new(
            name: name,
            version: version,
            provides: provides,
            metadata: metadata
          )
        end
      end

      def providers_for(extension_point)
        @mutex.synchronize do
          @plugins.flat_map { |m| Array(m.provides[extension_point]) }
        end
      end

      def all_plugins
        @mutex.synchronize { @plugins.dup }
      end

      def reset!
        @mutex.synchronize { @plugins = [] }
      end

      private

      def validate_provides!(provides)
        provides.each do |key, klass|
          unless EXTENSION_POINTS.include?(key)
            raise RegistrationError,
              "Unknown extension point #{key.inspect}. Valid: #{EXTENSION_POINTS.inspect}"
          end

          interface = INTERFACE_FOR[key].call
          Array(klass).each do |k|
            unless k.include?(interface)
              raise RegistrationError,
                "#{k} must include #{interface} to register as #{key}"
            end
          end
        end
      end

      # Called inside the mutex so it sees the current @plugins snapshot.
      # Only checks tool sets that already implement .tool_definitions — stubs
      # that include the interface module without implementing the full API
      # (common in unit tests) are skipped.
      def validate_mcp_tool_name_uniqueness!(provides)
        new_tool_sets = Array(provides[:mcp_tool_set]).select { |ts| ts.respond_to?(:tool_definitions) }
        return if new_tool_sets.empty?

        existing_names = @plugins
          .flat_map { |m| Array(m.provides[:mcp_tool_set]) }
          .select { |ts| ts.respond_to?(:tool_definitions) }
          .flat_map { |ts| ts.tool_definitions.map { |d| d[:name] } }

        new_tool_sets.each do |ts|
          ts.tool_definitions.each do |defn|
            if existing_names.include?(defn[:name])
              raise RegistrationError,
                "MCP tool name collision: #{defn[:name].inspect} is already registered by another tool set"
            end
          end
        end
      end
    end
  end
end
