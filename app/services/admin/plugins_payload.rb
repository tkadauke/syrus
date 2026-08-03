module Admin
  class PluginsPayload
    def as_json(*)
      {
        plugins: Syrus::PluginRegistry.all_plugins.map { |manifest| plugin_payload(manifest) }
      }
    end

    private

    def plugin_payload(manifest)
      spec = gem_spec_for(manifest)
      metadata = manifest.metadata.with_indifferent_access

      {
        name: manifest.name,
        version: manifest.version,
        enabled: manifest.enabled?,
        description: manifest.description.presence || spec&.summary || metadata[:description],
        homepage: manifest.homepage.presence || spec&.homepage || metadata[:homepage],
        author: author_for(spec, metadata),
        source: source_for(spec, metadata),
        extension_points: extension_points_payload(manifest)
      }
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
      available = provider.respond_to?(:available?) && provider.available?
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
