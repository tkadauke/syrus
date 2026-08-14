module Admin
  class PluginsPayload
    def initialize(query: nil)
      @query = query
    end

    def as_json(*)
      PerformanceLogging.phase("admin_plugins_payload") do
        manifests = Syrus::PluginRegistry.all_plugins
        manifests = filter_by_query(manifests) if @query.present?
        records = PluginRecord.where(name: manifests.map(&:name)).index_by(&:name)
        {
          plugins: manifests.map { |manifest| plugin_payload(manifest, records[manifest.name]) }
        }
      end
    end

    private

    def filter_by_query(manifests)
      matching_names = PerformanceLogging.phase("admin_plugins_payload.search", query: @query) do
        PluginRecord.search(@query).pluck(:name).to_set
      end
      manifests.select { |manifest| matching_names.include?(manifest.name) }
    end

    def plugin_payload(manifest, record = nil)
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
          description: manifest.description.presence || spec&.summary || metadata[:description],
          homepage: manifest.homepage.presence || spec&.homepage || metadata[:homepage],
          author: author_for(spec, metadata),
          source: source_for(spec, metadata),
          frontend: metadata[:frontend].presence || {},
          routes: Array(metadata[:routes]).map { |route| route.to_h },
          extension_points: PerformanceLogging.phase("admin_plugins.plugin.extension_points", plugin: manifest.name) { extension_points_payload(manifest) },
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
