module Syrus
  # The whole plugin interface: one file per plugin, declaring identity,
  # contributions, and effects. The framework owns *when* each of those runs,
  # because that turned out to be the thing plugin authors got wrong.
  #
  #   module Throughput
  #     extend Syrus::PluginApi
  #
  #     syrus_plugin "throughput" do
  #       default_enabled true
  #       disableable true
  #       experimental false
  #       requires_syrus nil
  #       display_name "Throughput"
  #       category     "observability"
  #       description  "Delivery throughput and landing waste."
  #
  #       provides repo_page_tab: "Throughput::RepoPageTabs"
  #       route :get, "/api/v1/app/repositories/:repository_id/throughput_metrics",
  #             to: "api/v1/app/repository_throughput#show"
  #
  #       while_enabled do |scope|
  #         scope.effect("filter subject") { Filters.register_subject(...) }
  #       end
  #     end
  #   end
  #
  # This file is required explicitly from config/application.rb before the
  # plugin loader runs, and excluded from autoloading. It has to exist at
  # plugin-entry load time -- before Zeitwerk initializes -- so
  # it must not reference anything outside itself at load time. Everything it
  # touches (Syrus::PluginRegistry, Syrus::Installer, the provider constants)
  # is resolved later, inside `to_prepare`.
  module PluginApi
    class Error < StandardError; end

    def syrus_plugin(name, &block)
      raise Error, "syrus_plugin requires a block" unless block

      # Rails::Engine.inherited infers the engine root from the call stack, and
      # from in here that is Syrus's own lib/ -- which resolves to the app root
      # and would hand the engine the whole application's paths. The plugin's
      # own lib/ is the only correct answer, and `called_from` is the only
      # window to say so: reading or writing `config` first triggers the
      # inference and raises.
      lib_dir = File.dirname(caller_locations(1, 1).first.absolute_path)

      definition = Definition.new(name: name.to_s, namespace: self, lib_dir: lib_dir)
      definition.instance_eval(&block)
      definition.build!
      @syrus_plugin_definition = definition
    end

    def syrus_plugin_definition = @syrus_plugin_definition

    # Registers now, rather than waiting for the next `to_prepare`. The engine
    # calls this itself; specs that reset the registry call it to put their
    # plugin back.
    def register! = syrus_plugin_definition.install!

    # One definition, instead of the same three lines copy-pasted into every
    # plugin -- which had drifted into two different meanings: eleven checked
    # the manifest's enabled flag, three asked whether the plugin's providers
    # were actually being handed out, which additionally accounts for health.
    #
    # The second is the one that matches what callers mean by "enabled": a
    # plugin whose hard dependency is disabled has its contributions withheld,
    # so reporting it as enabled would be a lie its own tools then act on.
    def enabled?
      name = syrus_plugin_definition.name
      manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == name }
      return false unless manifest&.enabled?

      Syrus::PluginRegistry.health.healthy?(name)
    end

    # Collects the declaration, then builds the engine and the registration
    # from it. Every setter is a plain reader when called with no argument, so
    # the definition can be introspected by specs and by the plugin itself.
    class Definition
      SCALARS = %i[
        display_name display_name_i18n_key description description_i18n_key
        long_description long_description_i18n_key homepage icon_url author category
        version default_enabled disableable experimental requires_syrus home_queue tick_interval prepare_priority
      ].freeze

      PROCESS_ROLES = %w[web worker preview sidecar].freeze

      # Spelled out rather than read from Syrus::Plugin::Declarations: this file
      # loads before the autoloader exists. A spec pins the two lists together.
      DECLARATION_POINTS = %i[
        workflow_kinds job_origin slug_type problem_provider
        repository_configuration step_environment worker_capability_probe
      ].freeze
      LISTS = %i[depends_on optionally_depends_on conflicts_with hosts config_schema cli_commands roles].freeze

      # Kept next to the DSL that accepts these keys so generated authoring
      # documentation cannot acquire a parallel manifest vocabulary.
      MANIFEST_KEYS = (SCALARS + LISTS + %i[
        provides route frontend events link links credential_type_names
        credential_types toolkit surface chat_integration review_contributions policy lifecycle data_policy
        agent_runtime execution_backend runtime_session source_host speech_to_text while_enabled metrics always suggests_enabling on_boot
      ] + DECLARATION_POINTS + %i[declare]).freeze

      attr_reader :name, :namespace, :lib_dir

      def initialize(name:, namespace:, lib_dir:)
        @name = name
        @namespace = namespace
        @lib_dir = lib_dir
        @scalars = { home_queue: :default, prepare_priority: 100 }
        @lists = {}
        @provides = {}
        @family_provides = []
        @declarations = {}
        @routes = []
        @links = []
        @metric_blocks = []
        @credential_types = []
        @frontend = {}
        @events = {}
        @effects = []
        @boot_blocks = []
        @suggestion = nil
      end

      SCALARS.each do |field|
        define_method(field) do |*args|
          return @scalars[field] if args.empty?

          @scalars[field] = args.first
        end
      end

      LISTS.each do |field|
        define_method(field) do |*args|
          return @lists.fetch(field, []) if args.empty?

          @lists[field] = args.flatten
        end
      end

      # Contribution classes are named as strings, resolved at registration.
      # A constant captured here would be captured once and go stale on the
      # next reload; a string is re-resolved every time, and cannot be
      # referenced before the plugin's own autoload paths exist.
      def provides(pairs = nil, key: nil, implements: nil, provisional: nil, **entries)
        entries[:key] = key if !key.nil? && !implements && !provisional
        pairs = (pairs || {}).merge(entries)
        return @provides if pairs.empty?

        if implements || provisional
          raise Error, "A family provides declaration must name exactly one family" unless pairs.size == 1
          family, providers = pairs.first
          Array(providers).each do |provider|
            @family_provides << Syrus::Plugin::FamilyDeclaration.build(
              family:, provider:, key:, implements: implements || [], provisional: provisional || []
            )
          end
          return
        end

        surface_keys = %i[sidebar_pages admin_pages repo_page_tabs workspace_tabs ui_slots artifact_renderers preview_panel_viewers]
        surface_entries = pairs.slice(*surface_keys)
        unless surface_entries.empty?
          surface(**surface_entries)
          pairs = pairs.except(*surface_keys)
        end

        @provides.merge!(pairs)
      end

      # Concise declaration for the toolkit facet. The generated provider is a
      # named plugin constant, so it remains reload-safe and appears normally
      # in capability catalogs and health diagnostics.
      def toolkit(workflow_tools: nil, chat_tools: nil, permissions: nil,
        run_context: nil, credential_probes: {}, secret_extractors: [])
        capabilities = {
          workflow_tools: workflow_tools,
          chat_tools: chat_tools,
          permissions: permissions,
          run_context: run_context,
          credential_probes: credential_probes.empty? ? nil : credential_probes,
          secret_extractors: secret_extractors.empty? ? nil : secret_extractors
        }.compact.keys
        return if capabilities.empty?

        provider = Syrus::Plugin::Toolkit.provider(
          key: name, display_name: @scalars[:display_name] || name.humanize,
          workflow_tools:, chat_tools:, permissions:, run_context:,
          credential_probes:, secret_extractors:
        )
        namespace.send(:remove_const, :Toolkit) if namespace.const_defined?(:Toolkit, false)
        namespace.const_set(:Toolkit, provider)
        stable = capabilities - [ :run_context ]
        @family_provides << Syrus::Plugin::FamilyDeclaration.build(
          family: :toolkit, provider: "#{namespace.name}::Toolkit",
          implements: stable, provisional: capabilities & [ :run_context ]
        )
      end

      # Declares UI surfaces and filter registrations without resolving the
      # plugin's application constants during manifest/catalog discovery.
      def surface(sidebar_pages: nil, admin_pages: nil, repo_page_tabs: nil,
        workspace_tabs: nil, ui_slots: nil, artifact_renderers: nil,
        preview_panel_viewers: nil, filter_subjects: {}, filter_chips: {})
        contributions = { sidebar_pages:, admin_pages:, repo_page_tabs:, workspace_tabs:,
          ui_slots:, artifact_renderers:, preview_panel_viewers: }.compact
        @surface_options ||= { filter_subjects: {}, filter_chips: {} }
        @surface_options.merge!(contributions)
        @surface_options[:filter_subjects].merge!(filter_subjects)
        @surface_options[:filter_chips].merge!(filter_chips)
        contributions = @surface_options.except(:filter_subjects, :filter_chips)
        filter_subjects = @surface_options[:filter_subjects]
        filter_chips = @surface_options[:filter_chips]
        capabilities = contributions.keys
        capabilities << :filter_subjects if filter_subjects.any?
        capabilities << :filter_chips if filter_chips.any?
        return if capabilities.empty?

        provider = Syrus::Plugin::Surface.provider(
          key: name, display_name: @scalars[:display_name] || name.humanize,
          filter_subjects:, filter_chips:, **contributions
        )
        namespace.send(:remove_const, :Surface) if namespace.const_defined?(:Surface, false)
        namespace.const_set(:Surface, provider)
        @family_provides.reject! { |entry| entry.family == :surface && entry.provider == "#{namespace.name}::Surface" }
        @family_provides << Syrus::Plugin::FamilyDeclaration.build(
          family: :surface, provider: "#{namespace.name}::Surface",
          implements: capabilities - [ :preview_panel_viewers ],
          provisional: capabilities & [ :preview_panel_viewers ]
        )
      end

      # Declares chat-turn integrations without resolving application constants
      # while plugin manifests and catalogs are loaded.
      def chat_integration(**contributions)
        contributions.compact!
        return if contributions.empty?

        provider = Syrus::Plugin::ChatIntegration.provider(
          key: name, display_name: @scalars[:display_name] || name.humanize, **contributions
        )
        namespace.send(:remove_const, :ChatIntegration) if namespace.const_defined?(:ChatIntegration, false)
        namespace.const_set(:ChatIntegration, provider)
        @family_provides << Syrus::Plugin::FamilyDeclaration.build(
          family: :chat_integration, provider: "#{namespace.name}::ChatIntegration",
          provisional: contributions.keys
        )
      end

      # Declares review-family contributions (gates, reviewer targets, review
      # context and presentation, post-implementation review, diff annotations,
      # adjudicators) without resolving application constants at load time.
      def review_contributions(**contributions)
        contributions.compact!
        return if contributions.empty?

        declare_contribution_family(:review, :ReviewContributions, Syrus::Plugin::ReviewContributions, contributions)
      end

      # Declares policy-family restrictions. Policy composition is fail-closed:
      # a restriction that cannot be evaluated hides rather than reveals.
      def policy(**contributions)
        contributions.compact!
        return if contributions.empty?

        declare_contribution_family(:policy, :Policy, Syrus::Plugin::Policy, contributions)
      end

      # Declares services for the service families. Services keep their own
      # interface modules; the declaration only names the plugin's service
      # classes (strings, resolved lazily) per capability.
      #
      #   agent_runtime agent_provider: "AgentProviders::Acme", chat_provider: "ChatProviders::Acme"
      def agent_runtime(agent_provider: nil, chat_provider: nil)
        declare_service_family(:agent_runtime, :AgentRuntimeServices, { agent_provider:, chat_provider: })
      end

      def execution_backend(execution_backend: nil)
        declare_service_family(:execution_backend, :ExecutionBackendServices, { execution_backend: })
      end

      def runtime_session(runtime_session_provider: nil)
        declare_service_family(:runtime_session, :RuntimeSessionServices, { runtime_session_provider: })
      end

      def source_host(source_control_provider: nil, input_source: nil, repository_content_provider: nil,
        workspace_git_transport: nil)
        declare_service_family(:source_host, :SourceHostServices,
          { source_control_provider:, input_source:, repository_content_provider:, workspace_git_transport: })
      end

      def speech_to_text(speech_to_text_provider: nil)
        declare_service_family(:speech_to_text, :SpeechToTextServices, { speech_to_text_provider: })
      end

      # Declares lifecycle hooks: plugin lifecycle callbacks and domain-event
      # subscribers. Hooks are broadcast; every enabled plugin's hook runs and a
      # failing one is isolated from the rest.
      def lifecycle(callback_providers: nil, domain_subscribers: nil)
        contributions = { callback_providers:, domain_subscribers: }.compact
        return if contributions.empty?

        declare_contribution_family(:lifecycle, :Lifecycle, Syrus::Plugin::Lifecycle, contributions)
      end

      # Declares data-governance hooks: retention definitions, purge
      # contributors, and retained-preview-panel decisions. A contributor that
      # fails is reported and never silently skipped.
      def data_policy(retention_policies: nil, purge_contributors: nil, preview_panel_retentions: nil)
        contributions = { retention_policies:, purge_contributors:, preview_panel_retentions: }.compact
        return if contributions.empty?

        declare_contribution_family(:data_policy, :DataPolicy, Syrus::Plugin::DataPolicy, contributions)
      end

      # Manifest declarations. Each is plain data validated here, while the
      # manifest is being parsed, so a malformed one fails with a message naming
      # this plugin and the field instead of surfacing later at the first call
      # site. Behavior a declaration cannot express as data is named by constant
      # string and loaded only when used; see Syrus::Plugin::Declarations.
      #
      #   workflow_kinds trigger_kinds: [ { kind: "briefing", template: "Briefing::Workflow", label: "Briefing", style: "bg-sky-100" } ],
      #                  step_kinds:    [ { kind: "briefing_run", handler: "Briefing::RunStep", label: "Briefing", style: "bg-sky-100", agentic: false } ],
      #                  job_kinds:     [ { kind: "briefing", infrastructure: true, issueless: true } ],
      #                  work_definitions: [ "Briefing::WorkDefinition" ]
      #   job_origin key: "nightly", provider: "Nightly::JobOrigin"
      #   slug_type prefix: "DOC", display_label: "Design Doc", resolver: "Docs::SlugResolver", client_path: "/docs/:id"
      #   problem_provider namespace: "briefing", kinds: [ { code: "briefing.stale", scope: "run", retryable: true, default_remediation: "restart_workflow" } ]
      #   repository_configuration key: "briefing.review", provider: "Briefing::RepositoryConfiguration", legacy_keys: [ "briefing" ]
      #   step_environment forwarded_env_keys: %w[BRIEFING_BUCKET], extra_env: "Briefing::RuntimeEnv"
      #   worker_capability_probe dimension: "runtime", token: "briefing_vm", probe: "Briefing::CapabilityProbe"
      DECLARATION_POINTS.each do |point|
        define_method(point) { |**attrs| declare(point, **attrs) }
      end

      def declare(point, **attrs)
        entry = Syrus::Plugin::Declarations.normalize!(name, point, attrs)
        (@declarations[point.to_sym] ||= []) << entry
        entry
      end

      def declarations = @declarations

      def route(verb, path, to:)
        @routes << { verb: verb.to_s.upcase, path: path, controller: to }
      end

      def declare_contribution_family(family, constant, owner, contributions)
        provider = owner.provider(key: name, display_name: @scalars[:display_name] || name.humanize, **contributions)
        namespace.send(:remove_const, constant) if namespace.const_defined?(constant, false)
        namespace.const_set(constant, provider)
        @family_provides.reject! { |entry| entry.family == family && entry.provider == "#{namespace.name}::#{constant}" }
        @family_provides << Syrus::Plugin::FamilyDeclaration.build(
          family:, provider: "#{namespace.name}::#{constant}", provisional: contributions.keys
        )
      end
      private :declare_contribution_family

      def declare_service_family(family, constant, services)
        services = services.compact
        return if services.empty?

        definition = Syrus::Plugin::Family.fetch(family)
        provider = Syrus::Plugin::ServiceProvider.build(
          key: name, display_name: @scalars[:display_name] || name.humanize, **services
        )
        namespace.send(:remove_const, constant) if namespace.const_defined?(constant, false)
        namespace.const_set(constant, provider)
        @family_provides.reject! { |entry| entry.family == family && entry.provider == "#{namespace.name}::#{constant}" }
        tiers = services.keys.group_by { |capability| definition.capabilities.fetch(capability).tier }
        @family_provides << Syrus::Plugin::FamilyDeclaration.build(
          family:, provider: "#{namespace.name}::#{constant}",
          implements: tiers.fetch(:stable, []), provisional: tiers.fetch(:provisional, [])
        )
      end
      private :declare_service_family

      def frontend(pairs = {})
        return @frontend if pairs.empty?

        @frontend.merge!(pairs)
      end

      def events(pairs = {})
        return @events if pairs.empty?

        @events.merge!(pairs)
      end

      def link(label, href, description: nil, kind: :surface, enabled_only: true)
        @links << {
          label: label.to_s,
          href: href.to_s,
          description: description,
          kind: kind.to_s,
          enabled_only: enabled_only != false
        }.compact
      end

      def links(entries = nil)
        return @links if entries.nil?

        Array(entries).each do |entry|
          attrs = entry.to_h.transform_keys(&:to_sym)
          link(attrs.fetch(:label), attrs.fetch(:href), description: attrs[:description], kind: attrs.fetch(:kind, :surface), enabled_only: attrs.fetch(:enabled_only, true))
        end
      end

      # Declares credential type names that credential-management plugins may
      # discover. Storage, encryption, parsing, authorization, broker
      # materialization, and redaction remain owned by the credential-management
      # implementation. A declaration may name its single typed broker consumer.
      def credential_type_names(*names)
        return @credential_types.map { |entry| entry.fetch(:name) } if names.empty?

        @credential_types.concat(names.flatten.map { |name| { name: name.to_s } })
      end

      def credential_types(entries = nil)
        return @credential_types if entries.nil?

        credential_type_entry_list(entries).each do |entry|
          attrs = entry.to_h.transform_keys(&:to_sym)
          @credential_types << {
            name: attrs.fetch(:name).to_s,
            label: attrs[:label],
            description: attrs[:description],
            typed_consumer: attrs[:typed_consumer]
          }.compact
        end
      end

      # Effects that belong to the plugin being *enabled*: torn down when it is
      # disabled, reinstalled when it is enabled again.
      def while_enabled(label = nil, &block)
        @effects << { scoped: true, label: label, block: block }
      end

      # Metrics the plugin owns, declared here so a plugin stays one
      # self-describing unit and deleting its directory takes its metrics with
      # it. Core cannot hold the list: a central file naming every metric would
      # make every plugin undeletable, which is what bin/plugin-boundary-audit
      # exists to prevent.
      #
      #   metrics do
      #     counter :relay_requests_total, tags: %i[outcome], comment: "..."
      #     histogram :relay_duration_seconds, buckets: [0.01, 0.25, 1, 5]
      #
      #     # The common case: one aggregate value on a timer. No sampler
      #     # class, tick_interval, or on_tick/on_metrics_scrape wiring
      #     # needed -- the framework samples the block on the shared
      #     # control-plane tick and caches the result.
      #     gauge :queue_depth, comment: "..." do
      #       RelayQueue.depth
      #     end
      #
      #     # The escape hatch: several gauges off one query pass, or a
      #     # counter/histogram that needs cursor-based cumulative logic
      #     # (see Metrics::QueueSampler). Must implement .sample!/.refresh_gauges!.
      #     sampler RelayMetricsSampler
      #   end
      #
      # Registered as a `while_enabled` effect, so a disabled plugin declares
      # nothing and emits no series. That is the correct reading of "disabled":
      # not zero, which would mean enabled-but-unused, but absent. The registry
      # applies the `syrus_<plugin>_` prefix itself, so a plugin cannot declare
      # into core's namespace. Any sampler the block declares -- a `gauge`
      # sample block or a `sampler <class>` -- lives and dies with the same
      # effect: it registers into Syrus::Metrics's sampler registry (the same
      # registry SampleGlobalMetricsJob and MetricsController iterate for
      # every sampler, core or plugin) here, and unregisters on the teardown
      # this effect returns, so a disabled plugin's sampler stops sampling
      # rather than going stale.
      def metrics(&block)
        raise Error, "metrics requires a block" unless block

        @metric_blocks << block
        plugin_name = name
        while_enabled("metrics") do |scope|
          scope.effect("metrics") do
            declared = Syrus::Metrics.declare_plugin(plugin_name, &block)
            samplers = build_samplers(plugin_name, block)
            samplers.each { |sampler| Syrus::Metrics.register_sampler(sampler) }

            lambda do
              samplers.each { |sampler| Syrus::Metrics.unregister_sampler(sampler) }
              Syrus::Metrics.undeclare(declared)
            end
          end
        end
      end

      # Effects that must hold whether the plugin is enabled or not. Owning
      # rows on a core record is the case that matters: disabling a plugin
      # stops it doing work, it does not orphan the data it already wrote, and
      # that data still has to go when its owner does.
      def always(label = nil, &block)
        @effects << { scoped: false, label: label, block: block }
      end

      # A reason this instance might want the plugin turned on, evaluated even
      # when it is disabled and has never been enabled -- the one tier that can
      # reach an admin who does not know the plugin exists.
      #
      # The block receives `Syrus::PluginSignals` and returns evidence (a
      # count, a list of repository slugs) or something falsy for "no". It may
      # only reach code under the plugin's `lib/`, which the gem requires at
      # load time; the plugin's `app/` tree is not eager loaded while it is
      # disabled, and a suggestion that woke it would defeat its own purpose.
      def suggests_enabling(reason, &block)
        raise Error, "suggests_enabling requires a block" unless block

        @suggestion = { reason: reason, block: block }
      end

      def suggestion = @suggestion

      # The escape hatch for process-level work that is not a registration at
      # all -- a daemon a worker process owns, say. Runs on every to_prepare
      # like everything else, so the block must be safe to re-enter; there is
      # no teardown, which is exactly why it is not an effect.
      def on_boot(&block)
        @boot_blocks << block
      end

      def effects = @effects
      def routes = @routes

      def build!
        missing = %i[default_enabled disableable experimental requires_syrus].reject { |field| @scalars.key?(field) }
        raise Error, "#{name} must declare #{missing.join(', ')}" if missing.any?

        invalid_roles = roles.map(&:to_s) - PROCESS_ROLES
        raise Error, "#{name} declares invalid process roles: #{invalid_roles.join(', ')}" if invalid_roles.any?

        build_engine!
        namespace.const_set(:Engine, @engine) unless namespace.const_defined?(:Engine, false)
      end

      private

      def build_engine!
        definition = self
        @engine = Class.new(::Rails::Engine)
        # Must precede any `config` access -- see the note in #syrus_plugin.
        @engine.called_from = lib_dir

        @engine.config.to_prepare { Syrus::PluginLoader.install_definition!(definition) }
        @engine
      end

      public

      # A definition whose deferred registration fails must not leave a
      # constant that looks like an available engine. Rails has no supported
      # Railtie removal API, so plugin routes are deliberately registry-backed;
      # removing the constant plus rolling back the registry makes it inert.
      def discard_engine!
        if namespace.const_defined?(:Engine, false) && namespace.const_get(:Engine, false).equal?(@engine)
          namespace.send(:remove_const, :Engine)
        end
        @engine = nil
      end

      # Runs on every `to_prepare`: at boot, and again after each code reload.
      # lib/ is autoloadable, so the registry it writes into is itself replaced
      # on reload -- registering once per boot would silently unregister the
      # plugin on the developer's first file save.
      def install!
        Syrus::PluginRegistry.register(**manifest_arguments)
        install_suggestion!
        install_effects!
        @boot_blocks.each(&:call)
      end

      def manifest_arguments
        release_posture = %i[default_enabled disableable experimental requires_syrus]
          .to_h { |field| [ field, @scalars.fetch(field) ] }
        {
          name: name,
          version: version || Syrus::PluginApi.default_version,
          provides: resolved_provides,
          family_provides: @family_provides,
          declarations: @declarations,
          events: events,
          routes: (routes if routes.any?),
          links: (links if links.any?),
          metrics: (metric_declarations if metric_declarations.any?),
          credential_types: (@credential_types if @credential_types.any?),
          frontend: (frontend if frontend.any?),
          plugin_root: File.expand_path("..", lib_dir)
        }.compact.merge(release_posture).merge(
          SCALARS.each_with_object({}) { |field, args| args[field] = @scalars[field] unless field == :version || release_posture.key?(field) }.compact
        ).merge(
          LISTS.each_with_object({}) { |field, args| args[field] = @lists[field] if @lists.key?(field) }
        )
      end

      def metric_declarations
        @metric_blocks.flat_map do |block|
          definitions = Syrus::Metrics::Declaration
            .new(owner: name, prefix: "#{name}_")
            .tap { |declaration| declaration.instance_eval(&block) }
            .definitions
          definitions.each(&:validate!)
          definitions.map(&:to_catalog_row)
        end
      end

      def resolved_provides
        @provides.each_with_object({}) do |(point, value), resolved|
          resolved[point] =
            if value.is_a?(Array)
              value.map { |entry| contribution(point, entry) }
            else
              contribution(point, value)
            end
        end
      end

      private

      def credential_type_entry_list(entries)
        if entries.respond_to?(:key?) && (entries.key?(:name) || entries.key?("name"))
          [ entries ]
        else
          Array(entries)
        end
      end

      # Evaluates the `metrics` block a second time through a scratch
      # Declaration -- the same double-evaluation `metric_declarations`
      # already uses for the catalog -- so sampler wiring stays independent
      # of the registry's own pass through Syrus::Metrics.declare_plugin,
      # which returns bare names rather than the full Definition objects
      # (see the "removes a plugin's metrics when it is undeclared" spec,
      # which depends on that names-array return shape).
      def build_samplers(plugin_name, block)
        declaration = Syrus::Metrics::Declaration
          .new(owner: plugin_name, prefix: "#{plugin_name}_")
          .tap { |d| d.instance_eval(&block) }

        gauge_samplers = declaration.definitions.filter_map do |definition|
          next unless definition.sample_block

          Syrus::Metrics::SampledGauge.new(definition: definition)
        end

        gauge_samplers + declaration.samplers
      end

      def resolve_constant(value)
        return value unless value.is_a?(String) || value.is_a?(Symbol)

        Object.const_get(value.to_s)
      rescue NameError => e
        raise Error, "#{name} declares #{value.inspect}, which does not resolve to a constant (#{e.message})"
      end

      # The registry requires a contribution to include its extension point's
      # interface, so fourteen engines reopened their own classes at boot to
      # add it -- and those includes were lost on the next reload, because the
      # class comes back fresh. Core already knows which interface each point
      # takes; deriving it is both less to write and impossible to forget.
      def contribution(point, value)
        klass = resolve_constant(value)
        interface = Syrus::PluginRegistry::INTERFACE_FOR[point.to_sym]
        return klass unless interface

        module_ = interface.call
        klass.include(module_) unless klass.include?(module_)
        klass
      end

      # Registered unconditionally, unlike effects: the whole point is to reach
      # an instance where the plugin is off. Registering a closure is not
      # running it -- nothing here touches the plugin until an admin asks.
      def install_suggestion!
        return if @suggestion.nil?

        Syrus::PluginRecommendations.register(
          plugin: name, reason: @suggestion[:reason], block: @suggestion[:block]
        )
      end

      def install_effects!
        @effects.each_with_index do |effect, index|
          kind = effect[:scoped] ? "while_enabled" : "always"
          # Stable across reloads, which is what the Installer keys on.
          label = effect[:label] ? "#{name}:#{effect[:label]}" : "#{name}:#{kind}:#{index}"
          # `always` is still scoped to the plugin -- just to a weaker
          # condition. It exists so disabling does not orphan rows the plugin
          # wrote; a plugin that was never enabled here wrote none.
          requires = effect[:scoped] ? :enabled : :ever_enabled

          Syrus::Plugin::Lifecycle.define_effect(label, plugin: name, requires: requires, &effect[:block])
        end
      end
    end

    # Bundled plugins ship with the app, so their gem version carries no
    # information -- all thirty said "0.1.0". A plugin that genuinely versions
    # independently can still declare one.
    def self.default_version = "0.1.0"
  end
end
