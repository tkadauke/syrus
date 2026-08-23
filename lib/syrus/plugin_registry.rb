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
      ci_log_parser
      preview_provider
      admin_page
      chat_mcp_tool_set
      source_control_provider
      artifact_renderer
      grader_augmentor
      callbacks
      platform_delivery
      prepare_detector
      review_criteria_provider
      autofix_command
      dependency_audit_command
      affected_test_analyzer
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
      ci_log_parser:           -> { Syrus::Plugin::CiLogParser },
      preview_provider:        -> { Syrus::Plugin::PreviewProvider },
      admin_page:              -> { Syrus::Plugin::AdminPage },
      chat_mcp_tool_set:       -> { Syrus::Plugin::ChatMcpToolSet },
      source_control_provider: -> { Syrus::Plugin::SourceControlProvider },
      artifact_renderer:       -> { Syrus::Plugin::ArtifactRenderer },
      grader_augmentor:        -> { Syrus::Plugin::GraderAugmentor },
      callbacks:               -> { Syrus::Plugin::Callbacks },
      platform_delivery:       -> { Syrus::Plugin::PlatformDelivery },
      prepare_detector:        -> { Syrus::Plugin::PrepareDetector },
      review_criteria_provider: -> { Syrus::Plugin::ReviewCriteriaProvider },
      autofix_command:         -> { Syrus::Plugin::AutofixCommand },
      dependency_audit_command: -> { Syrus::Plugin::DependencyAuditCommand },
      affected_test_analyzer:  -> { Syrus::Plugin::AffectedTestAnalyzer }
    }.freeze

    RegistrationError = Class.new(StandardError)
    PLUGIN_RECORD_CACHE_TTL = Rails.env.test? ? 0.seconds : 5.seconds

    @mutex            = Mutex.new
    @plugins          = []
    @direct_providers = Hash.new { |h, k| h[k] = [] }
    @plugin_record_cache_mutex = Mutex.new

    class << self
      # Two call forms:
      #
      # Manifest form — called by plugin gem engine initializers:
      #   register(name:, version:, provides: {}, ...)
      #
      # Direct form — registers a provider instance for a lightweight extension
      # point (e.g. :prompt_injector) without a full gem manifest:
      #   register(:prompt_injector, provider_instance)
      def register(*args, name: nil, version: nil, provides: {}, display_name: nil, description: nil, homepage: nil, icon_url: nil, default_enabled: true, disableable: true, category: nil, home_queue: :default, tick_interval: nil, config_schema: [], depends_on: [], prepare_priority: 100, **metadata)
        if args.length == 2 && (args[0].is_a?(Symbol) || args[0].is_a?(String))
          register_direct(args[0], args[1])
          return
        end


        validate_provides!(provides)
        validate_author!(metadata[:author])

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
            category:        category,
            home_queue:      home_queue,
            tick_interval:   tick_interval,
            config_schema:   config_schema,
            depends_on:      Array(depends_on).map(&:to_s),
            prepare_priority: prepare_priority
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
        ep = extension_point.to_sym
        unless EXTENSION_POINTS.include?(ep)
          raise ArgumentError, "Unknown extension point: #{extension_point.inspect}. Valid: #{EXTENSION_POINTS.inspect}"
        end

        manifest_providers = performance_phase("plugin_registry.providers_for", extension_point: ep) do
          plugins = performance_phase("plugin_registry.providers_for.snapshot", extension_point: ep) do
            @mutex.synchronize { @plugins.dup }
          end

          begin
            records = performance_phase("plugin_registry.providers_for.records", extension_point: ep, plugin_count: plugins.size) do
              records_for(plugins)
            end
            performance_phase("plugin_registry.providers_for.filter", extension_point: ep, plugin_count: plugins.size) do
              plugins
                .select { |m| plugin_enabled?(m, records[m.name]) }
                .then { |ms| sort_by_prepare_priority(ms) }
                .flat_map { |m| Array(m.provides[ep]) }
            end
          rescue ActiveRecord::ActiveRecordError
            sort_by_prepare_priority(plugins).flat_map { |m| Array(m.provides[ep]) }
          end
        end

        direct = @mutex.synchronize { @direct_providers[ep].dup }
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

      # Called once boot settles (see config/initializers/plugin_registry.rb) since
      # plugin engine initializer order isn't guaranteed - a plugin's depends_on
      # target may register after the dependent itself. Raises RegistrationError
      # listing every depends_on name that never resolved to a registered plugin;
      # callers decide whether to let that raise or just log it.
      def validate_dependencies!
        plugins = @mutex.synchronize { @plugins.dup }
        names = plugins.map(&:name).to_set

        errors = plugins.flat_map do |manifest|
          Array(manifest.depends_on).reject { |dep_name| names.include?(dep_name) }.map do |dep_name|
            "Plugin #{manifest.name.inspect} declares depends_on: #{dep_name.inspect}, which is not a registered plugin"
          end
        end

        raise RegistrationError, errors.join("; ") if errors.any?
      end

      def reset!
        @mutex.synchronize do
          @plugins = []
          @direct_providers = Hash.new { |h, k| h[k] = [] }
        end
        clear_plugin_record_cache!
      end

      def clear_plugin_record_cache!
        @plugin_record_cache_mutex.synchronize do
          @plugin_record_cache_by_name = nil
          @plugin_record_cache_expires_at = nil
        end
      end

      # A failed on_boot must not leave orphaned effects waiting for a
      # disable/shutdown that may never come, so a raise drains whatever
      # got registered before the failure (same policy as PluginLifecycleJob
      # applies to on_enable).
      def fire_boot_callbacks!
        providers_for(:callbacks).each do |provider|
          provider.on_boot
        rescue StandardError => e
          drain_effects_for_callback_provider(provider)
          Rails.logger.warn("[PluginRegistry] on_boot failed for #{provider}: #{e.class}: #{e.message}")
        end
      end

      # Always drains, success or failure, so a plugin's on_boot/on_enable
      # effects are guaranteed to run in reverse registration order on
      # process shutdown even though it doesn't route through
      # PluginLifecycleJob like the operator-triggered on_disable does.
      def fire_shutdown_callbacks!
        providers_for(:callbacks).each do |provider|
          provider.on_shutdown
        rescue StandardError => e
          Rails.logger.warn("[PluginRegistry] on_shutdown failed for #{provider}: #{e.class}: #{e.message}")
        ensure
          drain_effects_for_callback_provider(provider)
        end
      end

      private

      def drain_effects_for_callback_provider(provider)
        plugin_name = all_plugins.find { |m| Array(m.provides[:callbacks]).include?(provider) }&.name
        Syrus::Plugin::EffectRegistry.drain!(plugin_name) if plugin_name
      end

      # Lower prepare_priority runs/orders first; a stable index tiebreak
      # keeps registration order for plugins that don't set one (default 100
      # for all), so this is a no-op ordering change for every other
      # extension point.
      def sort_by_prepare_priority(plugins)
        plugins.sort_by.with_index { |m, i| [ m.prepare_priority, i ] }
      end

      def upsert_plugin_record!(name:, default_enabled:, disableable:, metadata:)
        record = PluginRecord.find_or_initialize_by(name: name)
        record.enabled = default_enabled if record.new_record?
        record.default_enabled = default_enabled if record.has_attribute?(:default_enabled)
        record.disableable = disableable if record.has_attribute?(:disableable)
        record.config = record.config.to_h.merge("manifest" => metadata)
        record.enabled = true if !disableable && !record.enabled?
        record.display_name = metadata[:display_name] if record.has_attribute?(:display_name)
        record.description = metadata[:description] if record.has_attribute?(:description)
        record.category = metadata[:category] if record.has_attribute?(:category)
        record.save!
      end

      def plugin_enabled?(manifest, record)
        return manifest.default_enabled? unless record
        return true unless manifest.disableable?

        record.effective_enabled?
      end

      def records_for(plugins)
        records = plugin_records_by_name.slice(*plugins.map(&:name))
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
        end
        records = plugin_records_by_name.slice(*plugins.map(&:name)) if missing.any?
        records
      end

      def plugin_records_by_name
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        @plugin_record_cache_mutex.synchronize do
          if @plugin_record_cache_by_name && @plugin_record_cache_expires_at.to_f > now
            return @plugin_record_cache_by_name
          end

          @plugin_record_cache_by_name = PluginRecord.all.index_by(&:name)
          @plugin_record_cache_expires_at = now + PLUGIN_RECORD_CACHE_TTL.to_f
          @plugin_record_cache_by_name
        end
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
        ep = extension_point.to_sym
        unless EXTENSION_POINTS.include?(ep)
          raise ArgumentError, "Unknown extension point: #{extension_point.inspect}. Valid: #{EXTENSION_POINTS.inspect}"
        end
        @mutex.synchronize { @direct_providers[ep] << provider }
      end

      # "Syrus" is not a real author - it's the product itself. Plugins must
      # credit an actual person or organization (blank/absent is still
      # allowed for lightweight test registrations).
      def validate_author!(author)
        return if author.blank?

        if author.to_s.strip.casecmp("syrus").zero?
          raise RegistrationError, "\"Syrus\" is not a valid plugin author"
        end
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
