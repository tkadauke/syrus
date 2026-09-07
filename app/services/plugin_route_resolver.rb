class PluginRouteResolver
  Route = Data.define(:verb, :path, :controller, :params, :plugin_name, :enabled)

  class << self
    def find(request, controller_prefix:)
      plugin_routes(enabled: true).find do |route|
        next false unless controller_allowed?(route.controller, controller_prefix)
        next false unless verb_matches?(route.verb, request.request_method)

        params = path_params_for(route.path, request.path)
        return route.with(params: params) if params

        false
      end
    end

    def find_disabled(request, controller_prefix:)
      plugin_routes(enabled: false).find do |route|
        next false unless controller_allowed?(route.controller, controller_prefix)
        next false unless verb_matches?(route.verb, request.request_method)

        params = path_params_for(route.path, request.path)
        return route.with(params: params) if params

        false
      end
    end

    def match?(request, controller_prefix:)
      find(request, controller_prefix: controller_prefix).present?
    end

    def declared_api_route?(request, controller_prefix:)
      find(request, controller_prefix: controller_prefix).present? ||
        find_disabled(request, controller_prefix: controller_prefix).present?
    end

    private

    def plugin_routes(enabled:)
      Syrus::PluginRegistry.all_plugins.flat_map do |manifest|
        next [] unless enabled.nil? || manifest.enabled? == enabled

        metadata = manifest.metadata.with_indifferent_access
        Array(metadata[:routes]).filter_map do |raw_route|
          route = raw_route.to_h.with_indifferent_access
          next if route[:controller].blank? || route[:path].blank?

          Route.new(
            verb: route[:verb].presence || "GET",
            path: route[:path].to_s,
            controller: route[:controller].to_s,
            params: {},
            plugin_name: manifest.name,
            enabled: manifest.enabled?
          )
        end
      end
    end

    def controller_allowed?(controller, prefix)
      controller.start_with?(prefix) && controller != "#{prefix}plugin_routes#dispatch"
    end

    def verb_matches?(declared, actual)
      verbs = Array(declared).flat_map { |verb| verb.to_s.split(/[,\s]+/) }.map(&:upcase)
      verbs.include?("ANY") || verbs.include?(actual.to_s.upcase)
    end

    def path_params_for(pattern, path)
      names = []
      regex_source = pattern.split("/").map do |segment|
        if segment.start_with?(":")
          names << segment.delete_prefix(":").to_sym
          "([^/]+)"
        else
          Regexp.escape(segment)
        end
      end.join("/")

      match = /\A#{regex_source}\z/.match(path)
      return unless match

      names.zip(match.captures).to_h
    end
  end
end
