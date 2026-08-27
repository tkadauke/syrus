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
    def initialize(query: nil, params: nil, user: nil)
      @query = query
      @params = params
      @user = user
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
          plugins: manifests.map { |manifest| plugin_payload(manifest, records[manifest.name], dependency_graph) }
        }
        payload.merge!(filter: filter.to_h, controls: controls_json) if @params
        payload
      end
    end

    private

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

    def plugin_payload(manifest, record, dependency_graph)
      PerformanceLogging.phase("admin_plugins.plugin", plugin: manifest.name) do
        spec = PerformanceLogging.phase("admin_plugins.plugin.gem_spec", plugin: manifest.name) { gem_spec_for(manifest) }
        metadata = manifest.metadata.with_indifferent_access

        {
          disable_blockers: disable_blockers_payload(manifest),
          name: manifest.name,
          display_name: manifest.display_name.presence || metadata[:display_name].presence || manifest.name.to_s.titleize,
          version: manifest.version,
          enabled: manifest.enabled?,
          default_enabled: manifest.default_enabled?,
          disableable: manifest.disableable?,
          category: manifest.category,
          category_label: Syrus::Plugin::Category.label_for(manifest.category),
          description: manifest.description.presence || spec&.summary || metadata[:description],
          long_description: manifest.long_description.presence || metadata[:long_description],
          homepage: manifest.homepage.presence || spec&.homepage || metadata[:homepage],
          icon_url: manifest.icon_url.presence || metadata[:icon_url].presence || FALLBACK_ICON_URL,
          author: author_for(spec, metadata),
          source: source_for(spec, metadata),
          frontend: metadata[:frontend].presence || {},
          routes: Array(metadata[:routes]).map { |route| route.to_h },
          extension_points: PerformanceLogging.phase("admin_plugins.plugin.extension_points", plugin: manifest.name) { extension_points_payload(manifest) },
          depends_on: Array(manifest.depends_on),
          dependents: dependency_graph.dependents_for(manifest.name),
          **Admin::PluginConfigPayload.new(manifest, record).as_json
        }
      end
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
            class_name: provider.name || provider.to_s,
            availability: availability_for(extension_point, provider)
          }
        end
      end
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
      available = provider.respond_to?(:available?) && PerformanceLogging.plugin_call(extension_point: :agent_provider, provider: provider, operation: :available) { provider.available? }
      {
        status: available ? "available" : "unavailable",
        label: available ? "Available" : "Unavailable"
      }
    rescue StandardError => e
      {
        status: "error",
        label: "Availability check failed",
        detail: e.message
      }
    end

    def input_source_availability(provider)
      configured_count = PerformanceLogging.plugin_call(extension_point: :input_source, provider: provider, operation: :configured_count) do
        InputSource.where(type: provider.name).count
      end
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
