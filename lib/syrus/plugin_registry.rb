module Syrus
  class PluginRegistry
    EXTENSION_POINTS = %i[
      agent_provider
      chat_provider
      mcp_tool_set
      input_source
      prompt_injector
      test_result_parser
      coverage_analyzer
      preview_provider
      admin_page
      chat_mcp_tool_set
      source_control_provider
      artifact_renderer
    ].freeze

    # Lambdas defer constant resolution until call time (autoload-friendly).
    INTERFACE_FOR = {
      agent_provider:          -> { Syrus::Plugin::AgentProvider },
      chat_provider:           -> { Syrus::Plugin::ChatProvider },
      mcp_tool_set:            -> { Syrus::Plugin::McpToolSet },
      input_source:            -> { Syrus::Plugin::InputSource },
      prompt_injector:         -> { Syrus::Plugin::PromptInjector },
      test_result_parser:      -> { Syrus::Plugin::TestResultParser },
      coverage_analyzer:       -> { Syrus::Plugin::CoverageAnalyzer },
      preview_provider:        -> { Syrus::Plugin::PreviewProvider },
      admin_page:              -> { Syrus::Plugin::AdminPage },
      chat_mcp_tool_set:       -> { Syrus::Plugin::ChatMcpToolSet },
      source_control_provider: -> { Syrus::Plugin::SourceControlProvider },
      artifact_renderer:       -> { Syrus::Plugin::ArtifactRenderer }
    }.freeze

    RegistrationError = Class.new(StandardError)

    @mutex            = Mutex.new
    @plugins          = []
    @direct_providers = Hash.new { |h, k| h[k] = [] }

    class << self
      # Two call forms:
      #
      # Manifest form — called by plugin gem engine initializers:
      #   register(name:, version:, provides: {}, ...)
      #
      # Direct form — registers a provider instance for a lightweight extension
      # point (e.g. :prompt_injector) without a full gem manifest:
      #   register(:prompt_injector, provider_instance)
      def register(*args, name: nil, version: nil, provides: {}, display_name: nil, description: nil, homepage: nil, icon_url: nil, default_enabled: true, disableable: true, category: nil, **metadata)
        if args.length == 2 && args[0].is_a?(Symbol)
          register_direct(args[0], args[1])
          return
        end


        validate_provides!(provides)

        @mutex.synchronize do
          validate_mcp_tool_name_uniqueness!(provides)
          @plugins << Syrus::Plugin::Manifest.new(
            name:            name,
            display_name:    display_name,
            version:         version,
            provides:        provides,
            metadata:        metadata,
            description:     description,
            homepage:        homepage,
            icon_url:        icon_url,
            default_enabled: default_enabled,
            disableable:     disableable,
            category:        category
          )
        end

        begin
          upsert_plugin_record!(
            name: name,
            default_enabled: default_enabled,
            disableable: disableable,
            metadata: {
              version: version,
              display_name: display_name,
              description: description,
              homepage: homepage,
              icon_url: icon_url,
              category: category
            }.compact
          )
        rescue ActiveRecord::ActiveRecordError
          # Table/database not available (e.g. asset precompile or
          # db:schema:load in progress). Ignore - the registry operates in
          # memory; the DB record will be created on first boot with DB access.
        end
      end

      # Returns provider classes (manifest) and provider instances (direct) for
      # the given extension point that belong to currently-enabled plugins.
      # Falls back to all registered plugins when the plugin_records table
      # doesn't exist yet.
      def providers_for(extension_point)
        manifest_providers = performance_phase("plugin_registry.providers_for", extension_point: extension_point) do
          plugins = performance_phase("plugin_registry.providers_for.snapshot", extension_point: extension_point) do
            @mutex.synchronize { @plugins.dup }
          end

          begin
            records = performance_phase("plugin_registry.providers_for.records", extension_point: extension_point, plugin_count: plugins.size) do
              records_for(plugins)
            end
            performance_phase("plugin_registry.providers_for.filter", extension_point: extension_point, plugin_count: plugins.size) do
              plugins
                .select { |m| plugin_enabled?(m, records[m.name]) }
                .flat_map { |m| Array(m.provides[extension_point]) }
            end
          rescue ActiveRecord::ActiveRecordError
            plugins.flat_map { |m| Array(m.provides[extension_point]) }
          end
        end

        direct = @mutex.synchronize { @direct_providers[extension_point].dup }
        manifest_providers + direct
      end

      # Returns a snapshot of all registered manifests, each annotated with the
      # current enabled state from PluginRecord. Falls back to enabled: true
      # for every plugin when the table doesn't exist yet.
      def all_plugins
        performance_phase("plugin_registry.all_plugins") do
          plugins = performance_phase("plugin_registry.all_plugins.snapshot") do
            @mutex.synchronize { @plugins.dup }
          end

          begin
            records = performance_phase("plugin_registry.all_plugins.records", plugin_count: plugins.size) do
              records_for(plugins)
            end
            performance_phase("plugin_registry.all_plugins.annotate", plugin_count: plugins.size) do
              plugins.map do |m|
                record = records[m.name]
                record ? manifest_with_record(m, record) : m
              end
            end
          rescue ActiveRecord::ActiveRecordError
            plugins
          end
        end
      end

      def registered_names
        @mutex.synchronize { @plugins.map(&:name) }
      end

      def reset!
        @mutex.synchronize do
          @plugins = []
          @direct_providers = Hash.new { |h, k| h[k] = [] }
        end
      end

      private

      def upsert_plugin_record!(name:, default_enabled:, disableable:, metadata:)
        record = PluginRecord.find_or_initialize_by(name: name)
        record.enabled = default_enabled if record.new_record?
        record.default_enabled = default_enabled if record.has_attribute?(:default_enabled)
        record.disableable = disableable if record.has_attribute?(:disableable)
        record.config = record.config.to_h.merge("manifest" => metadata)
        record.enabled = true if !disableable && !record.enabled?
        record.save!
      end

      def plugin_enabled?(manifest, record)
        return manifest.default_enabled? unless record
        return true unless manifest.disableable?

        record.effective_enabled?
      end

      def records_for(plugins)
        records = PluginRecord.where(name: plugins.map(&:name)).index_by(&:name)
        missing = plugins.reject { |manifest| records.key?(manifest.name) }
        missing.each do |manifest|
          upsert_plugin_record!(
            name: manifest.name,
            default_enabled: manifest.default_enabled,
            disableable: manifest.disableable,
            metadata: manifest.metadata.to_h.merge(
              version: manifest.version,
              display_name: manifest.display_name,
              description: manifest.description,
              homepage: manifest.homepage,
              icon_url: manifest.icon_url,
              category: manifest.category
            ).compact
          )
          records[manifest.name] = PluginRecord.find_by!(name: manifest.name)
        end
        records
      end

      def manifest_with_record(manifest, record)
        manifest.with(
          enabled: record.effective_enabled?,
          default_enabled: record.has_attribute?(:default_enabled) ? record.default_enabled : manifest.default_enabled,
          disableable: record.has_attribute?(:disableable) ? record.disableable : manifest.disableable
        )
      end

      def performance_phase(name, metadata = {}, &block)
        if defined?(PerformanceLogging)
          PerformanceLogging.phase(name, metadata, &block)
        else
          yield
        end
      end

      def register_direct(extension_point, provider)
        unless EXTENSION_POINTS.include?(extension_point)
          raise ArgumentError, "Unknown extension point: #{extension_point.inspect}. Valid: #{EXTENSION_POINTS.inspect}"
        end
        @mutex.synchronize { @direct_providers[extension_point] << provider }
      end

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
      # Only checks tool sets that already implement .tool_definitions - stubs
      # that include the interface module without implementing the full API
      # (common in unit tests) are skipped.
      def validate_mcp_tool_name_uniqueness!(provides)
        new_tool_sets = (Array(provides[:mcp_tool_set]) + Array(provides[:chat_mcp_tool_set]))
          .select { |ts| ts.respond_to?(:tool_definitions) }
        return if new_tool_sets.empty?

        existing_plugin_names = @plugins
          .flat_map { |m| Array(m.provides[:mcp_tool_set]) + Array(m.provides[:chat_mcp_tool_set]) }
          .select { |ts| ts.respond_to?(:tool_definitions) }
          .flat_map { |ts| safe_tool_definitions(ts).map { |d| d[:name] } }
        existing_names = core_mcp_tool_names + existing_plugin_names

        new_tool_sets.each do |ts|
          safe_tool_definitions(ts).each do |defn|
            if existing_names.include?(defn[:name])
              raise RegistrationError,
                "MCP tool name collision: #{defn[:name].inspect} is already registered by another tool set"
            end
          end
        end
      end

      def safe_tool_definitions(tool_set)
        method = tool_set.method(:tool_definitions)
        keywords = method.parameters.select { |type, _name| type == :key || type == :keyreq }.map(&:last)
        if keywords.include?(:context)
          tool_set.tool_definitions(context: nil)
        elsif keywords.include?(:tier)
          tool_set.tool_definitions(tier: nil)
        elsif method.arity.zero?
          tool_set.tool_definitions
        else
          tool_set.tool_definitions
        end
      end

      def core_mcp_tool_names
        return [] unless defined?(SyrusMcp::CoreToolSet)

        safe_tool_definitions(SyrusMcp::CoreToolSet).map { |d| d[:name] }
      rescue NameError
        []
      end
    end
  end
end
