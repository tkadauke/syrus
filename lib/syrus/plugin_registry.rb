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
      # Auto-upserts a PluginRecord so the operator can enable/disable the plugin
      # without touching the Gemfile. Does not overwrite an existing enabled state.
      def register(name:, version:, provides: {}, description: nil, homepage: nil, icon_url: nil, **metadata)
        validate_provides!(provides)

        @mutex.synchronize do
          validate_mcp_tool_name_uniqueness!(provides)
          @plugins << Syrus::Plugin::Manifest.new(
            name:        name,
            version:     version,
            provides:    provides,
            metadata:    metadata,
            description: description,
            homepage:    homepage,
            icon_url:    icon_url
          )
        end

        begin
          PluginRecord.find_or_create_by!(name: name)
        rescue ActiveRecord::ActiveRecordError
          # Table/database not available (e.g. asset precompile or
          # db:schema:load in progress). Ignore — the registry operates in
          # memory; the DB record will be created on first boot with DB access.
        end
      end

      # Returns only the provider classes for the given extension point that
      # belong to currently-enabled plugins. Falls back to all registered
      # plugins when the plugin_records table doesn't exist yet.
      def providers_for(extension_point)
        plugins = @mutex.synchronize { @plugins.dup }

        begin
          enabled_names = PluginRecord.where(enabled: true).pluck(:name).to_set
          plugins
            .select { |m| enabled_names.include?(m.name) }
            .flat_map { |m| Array(m.provides[extension_point]) }
        rescue ActiveRecord::ActiveRecordError
          plugins.flat_map { |m| Array(m.provides[extension_point]) }
        end
      end

      # Returns a snapshot of all registered manifests, each annotated with the
      # current enabled state from PluginRecord. Falls back to enabled: true
      # for every plugin when the table doesn't exist yet.
      def all_plugins
        plugins = @mutex.synchronize { @plugins.dup }

        begin
          records = PluginRecord.all.index_by(&:name)
          plugins.map do |m|
            record = records[m.name]
            record ? m.with(enabled: record.enabled) : m
          end
        rescue ActiveRecord::ActiveRecordError
          plugins
        end
      end

      def registered_names
        @mutex.synchronize { @plugins.map(&:name) }
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
