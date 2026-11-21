module Admin
  class PluginsPayload
    FALLBACK_ICON_URL = "/plugin-icons/spqr_eagle.svg"

    # `query:` is the legacy plain-text full search param, still used by the
    # bearer-token REST admin API (Api::V1::Admin::PluginsController) so
    # external tooling built against `?q=<text>` keeps working unchanged.
    # `params:`/`user:` drive the newer Filters:: chip framework (category +
    # search chips) used by the SPA's FilterBar on /admin/plugins — passing
    # `params:` switches this payload into that mode and adds `filter`/
    # `controls` to the JSON the same way Admin::Queue::Payload and
    # Admin::Users::Payload do.
    def initialize(query: nil, params: nil, user: nil, detail: false)
      @query = query
      @params = params
      @user = user
      @detail = detail
    end

    def as_json(*)
      PerformanceLogging.phase("admin_plugins_payload") do
        all_manifests = Syrus::PluginRegistry.all_plugins
        manifests = filtered_manifests(all_manifests)
        records = PluginRecord.where(name: manifests.map(&:name)).index_by(&:name)
        # Dependency graph is built from *all* registered manifests, not the
        # filtered set, so a search hit still shows dependents/dependencies
        # that fell outside the query.
        dependency_graph = Admin::PluginDependencyGraph.new(all_manifests)
        payload = {
          recovery: recovery_payload,
          beta_mode_enabled: AppSetting.beta_mode_enabled?,
          convergence: PluginDesiredState::Convergence.new.as_json,
          plugins: manifests.map { |manifest| plugin_payload(manifest, records[manifest.name], dependency_graph) }
        }
        payload.merge!(filter: filter.to_h, controls: controls_json) if @params
        payload
      end
    end

    def show(name)
      PerformanceLogging.phase("admin_plugin_payload.show", plugin: name) do
        all_manifests = Syrus::PluginRegistry.all_plugins
        manifest = all_manifests.find { |candidate| candidate.name == name.to_s }
        raise ActiveRecord::RecordNotFound, "Couldn't find Plugin #{name.inspect}" unless manifest

        records = PluginRecord.where(name: [ manifest.name ]).index_by(&:name)
        dependency_graph = Admin::PluginDependencyGraph.new(all_manifests)

        {
          beta_mode_enabled: AppSetting.beta_mode_enabled?,
          plugin: plugin_payload(manifest, records[manifest.name], dependency_graph, detail: true)
        }
      end
    end

    private

    def recovery_payload
      safety = boot_safety
      { safe_mode: safety.mode, quarantines:, locally_clearable: clearable_quarantine_names.to_a }
    end

    def boot_safety = @boot_safety ||= Syrus::PluginBootSafety.default
    def quarantines = @quarantines ||= boot_safety.quarantines
    def local_quarantines = @local_quarantines ||= boot_safety.local_quarantines

    def clearable_quarantine_names
      @clearable_quarantine_names ||= if boot_safety.mode.to_s.empty?
        (local_quarantines.keys - boot_safety.fleet_quarantines.keys).to_set
      else
        Set.new
      end
    end

    def filter
      @filter ||= ::Admin::Plugins::Filter.from_params(@params || {}, user: @user)
    end

    def controls_json
      { filter_schema: Filters::Schema.for(subject: :admin_plugins, user: @user) }
    end

    def filtered_manifests(all_manifests)
      if @params
        filter.active? ? filter_by_tree(all_manifests) : all_manifests
      elsif @query.present?
        filter_by_query(all_manifests)
      else
        all_manifests
      end
    end

    def filter_by_tree(manifests)
      matching_names = PerformanceLogging.phase("admin_plugins_payload.filter", tree: filter.to_h) do
        filter.apply(PluginRecord.all).pluck(:name).to_set
      end
      manifests.select { |manifest| matching_names.include?(manifest.name) }
    end

    def filter_by_query(manifests)
      matching_names = PerformanceLogging.phase("admin_plugins_payload.search", query: @query) do
        PluginRecord.search(@query).pluck(:name).to_set
      end
      manifests.select { |manifest| matching_names.include?(manifest.name) }
    end

    def plugin_payload(manifest, record, dependency_graph, detail: @detail)
      PerformanceLogging.phase("admin_plugins.plugin", plugin: manifest.name) do
        spec = PerformanceLogging.phase("admin_plugins.plugin.gem_spec", plugin: manifest.name) { gem_spec_for(manifest) }
        metadata = manifest.metadata.with_indifferent_access

        payload = {
          disable_blockers: disable_blockers_payload(manifest),
          name: manifest.name,
          display_name: manifest.display_name.presence || metadata[:display_name].presence || manifest.name.to_s.titleize,
          display_name_i18n_key: manifest.display_name_i18n_key,
          version: manifest.version,
          enabled: manifest.enabled?,
          default_enabled: manifest.default_enabled?,
          disableable: manifest.disableable?,
          experimental: manifest.experimental?,
          category: manifest.category,
          category_label: Syrus::Plugin::Category.label_for(manifest.category),
          description: manifest.description.presence || spec&.summary || metadata[:description],
          description_i18n_key: manifest.description_i18n_key,
          long_description: manifest.long_description.presence || metadata[:long_description],
          long_description_i18n_key: manifest.long_description_i18n_key,
          homepage: manifest.homepage.presence || spec&.homepage || metadata[:homepage],
          icon_url: manifest.icon_url.presence || metadata[:icon_url].presence || FALLBACK_ICON_URL,
          author: author_for(spec, metadata),
          source: source_for(spec, metadata),
          frontend: metadata[:frontend].presence || {},
          routes: Array(metadata[:routes]).map { |route| route.to_h },
          links: links_payload(manifest),
          extension_points: PerformanceLogging.phase("admin_plugins.plugin.extension_points", plugin: manifest.name) { extension_points_payload(manifest) },
          capabilities: capability_payload(manifest),
          depends_on: Array(manifest.depends_on),
          optionally_depends_on: Array(manifest.optionally_depends_on),
          conflicts_with: Array(manifest.conflicts_with),
          dependents: dependency_graph.dependents_for(manifest.name),
          health: health_payload(manifest, record),
          quarantine_clearable: clearable_quarantine_names.include?(manifest.name),
          recommendation: recommendation_payload(manifest),
          **Admin::PluginConfigPayload.new(manifest, record).as_json
        }
        unless detail
          payload.except!(
            :long_description, :long_description_i18n_key, :homepage, :author, :source,
            :frontend, :routes, :links, :extension_points, :optionally_depends_on,
            :conflicts_with, :config_schema, :config
          )
        end
        payload.merge!(docs: docs_payload(manifest, spec), metrics: metrics_payload(manifest)) if detail
        payload
      end
    end

    def links_payload(manifest)
      Array(manifest.links).map do |link|
        link.with_indifferent_access.slice(:label, :href, :description, :kind, :enabled_only)
      end
    end

    def docs_payload(manifest, spec)
      docs_dir = docs_dir_for(manifest, spec)
      return [] unless docs_dir&.directory?

      docs_dir.children
        .select { |path| path.file? && path.extname == ".md" }
        .sort_by(&:to_s)
        .map do |path|
          body = path.read
          {
            title: body[/\A#\s+(.+)$/, 1].presence || path.basename(".md").to_s.humanize,
            path: path.relative_path_from(Rails.root).to_s,
            body: body
          }
        end
    end

    def docs_dir_for(manifest, spec)
      candidates = [
        spec&.full_gem_path && Pathname(spec.full_gem_path).join("docs/syrus_docs"),
        Syrus::PluginRoots.default.resolve(manifest.name)&.join("docs/syrus_docs"),
        Syrus::PluginRoots.default.resolve(manifest.name.tr("-", "_"))&.join("docs/syrus_docs")
      ].compact
      candidates.find(&:directory?) || candidates.first
    end

    def metrics_payload(manifest)
      declared = Array(manifest.metrics)
      live_names = Syrus::Metrics.definitions.select { |definition| definition.owner.to_s == manifest.name.to_s }.map { |definition| definition.name.to_s }.to_set

      declared.map do |metric|
        metric = metric.with_indifferent_access
        {
          name: metric[:name].to_s,
          type: metric[:type].to_s,
          tags: Array(metric[:tags]).map(&:to_s),
          comment: metric[:comment].to_s,
          available: live_names.include?(metric[:name].to_s)
        }
      end
    end

    # Why this instance might want a plugin it currently has off. Present only
    # for disabled plugins with a signal that actually fired -- an enabled
    # plugin needs no introduction, and a nudge without evidence is noise.
    def recommendation_payload(manifest)
      recommendation = recommendations[manifest.name]
      return nil unless recommendation

      { reason: recommendation.reason, evidence: recommendation.evidence_summary }
    end

    # Evaluated once for the whole payload: the signals behind it are
    # instance-wide, and re-deriving them per plugin would turn one set of
    # counts into thirty.
    def recommendations
      @recommendations ||= PerformanceLogging.phase("admin_plugins_payload.recommendations") do
        Syrus::PluginRecommendations.call.index_by(&:plugin)
      end
    end

    # An unhealthy plugin is enabled but inert - its providers are withheld.
    # Surfacing the state and the specific unmet dependency is what lets an
    # operator fix a degraded instance instead of guessing why a plugin's
    # behavior vanished.
    def health_payload(manifest, record)
      if (reason = quarantines[manifest.name])
        return { state: "quarantined", reasons: [ reason ] }
      end

      status = plugin_health.status(manifest.name)
      runtime = Syrus::PluginInvocation.runtime_health
      failures = runtime.failures(plugin: manifest.name).map(&:to_h)
      circuits = runtime.circuits(plugin: manifest.name).map(&:to_h)
      state = if circuits.any?
        "circuit_open"
      elsif failures.any? && (status.nil? || status.healthy?)
        "degraded"
      else
        status&.state&.to_s || "ok"
      end
      payload = {
        state: state,
        reasons: status&.reasons || [],
        request_count: record&.request_count.to_i,
        last_error_at: record&.last_error_at&.iso8601
      }
      payload[:jobs] = plugin_job_health(manifest, record)
      payload[:failures] = failures if failures.any?
      payload[:circuits] = circuits if circuits.any?
      scan = manifest.metadata.to_h[:plugin_host_surface_scan]
      payload[:host_surface] = scan.to_h.merge(
        public: scan.public.map(&:to_h), legacy: scan.legacy.map(&:to_h), unlisted: scan.unlisted.map(&:to_h),
        dynamic: scan.dynamic.map(&:to_h)
      ) if scan
      payload
    end

    def plugin_job_health(manifest, record)
      queue_name = "plugin_#{manifest.name}"
      recorded = record&.config&.dig("job_health") || {}
      plugin_job_counts.for(manifest.name, default_queue: queue_name).merge(
        discarded_count: recorded["discarded_count"].to_i,
        last_error: recorded["last_error"],
        last_discarded_at: recorded["last_discarded_at"]
      )
    end

    def plugin_job_counts
      @plugin_job_counts ||= Admin::PluginJobHealth.new
    end

    def plugin_health
      @plugin_health ||= Syrus::PluginRegistry.health
    end

    def disable_blockers_payload(manifest)
      Admin::PluginDisableGuard.blockers_for(manifest).map do |blocker|
        {
          kind: blocker.kind,
          label: blocker.label,
          count: blocker.count
        }
      end
    end

    def extension_points_payload(manifest)
      manifest.provides.flat_map do |extension_point, providers|
        Array(providers).map do |provider|
          {
            extension_point: extension_point.to_s,
            class_name: provider_class_name(provider),
            availability: availability_for(extension_point, provider)
          }
        end
      end
    end

    def capability_payload(manifest)
      manifest.family_provides.flat_map do |declaration|
        declaration.capabilities.map do |capability|
          {
            family: declaration.family.to_s,
            capability: capability.to_s,
            provider: declaration.provider,
            key: declaration.key&.to_s,
            tier: declaration.provisional.include?(capability) ? "provisional" : "stable",
            priority: manifest.prepare_priority
          }
        end
      end
    end

    def provider_class_name(provider)
      return provider.name || provider.to_s if provider.respond_to?(:name)

      provider.to_h.with_indifferent_access[:provider].presence || provider.to_s
    end

    def availability_for(extension_point, provider)
      case extension_point.to_sym
      when :agent_provider
        agent_provider_availability(provider)
      when :input_source
        input_source_availability(provider)
      else
        { status: "registered", label: "Registered" }
      end
    end

    def agent_provider_availability(provider)
      invocation = if provider.respond_to?(:available?)
        Syrus::PluginInvocation.call(
          extension_point: :agent_provider, provider:, operation: :available, on_decline: false
        ) { provider.available? }
      end
      if invocation.is_a?(Syrus::PluginInvocation::Failed)
        return { status: "error", label: "Availability check failed", detail: invocation.message }
      end
      available = invocation && Syrus::PluginInvocation.value(invocation)
      {
        status: available ? "available" : "unavailable",
        label: available ? "Available" : "Unavailable"
      }
    end

    def input_source_availability(provider)
      configured_count = InputSource.where(type: provider.name).count
      {
        status: configured_count.positive? ? "configured" : "not_configured",
        label: configured_count.positive? ? "Configured" : "Not configured",
        configured_count: configured_count
      }
    end

    def gem_spec_for(manifest)
      names = [
        manifest.name.to_s,
        manifest.name.to_s.tr("-", "_"),
        manifest.name.to_s.tr("_", "-")
      ].uniq

      names.filter_map { |name| Gem.loaded_specs[name] }.first
    end

    def author_for(spec, metadata)
      authors = Array(spec&.authors).map(&:presence).compact
      authors.presence&.join(", ") || metadata[:author]
    end

    def source_for(spec, metadata)
      spec&.full_gem_path.presence || metadata[:source].presence || metadata[:source_url]
    end
  end
end
