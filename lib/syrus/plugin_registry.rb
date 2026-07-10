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
    end
  end
end
