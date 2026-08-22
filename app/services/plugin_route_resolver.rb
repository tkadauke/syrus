class PluginRouteResolver
  Route = Data.define(:verb, :path, :controller, :params)

  class << self
    def find(request, controller_prefix:)
      plugin_routes.find do |route|
        next false unless controller_allowed?(route.controller, controller_prefix)
        next false unless verb_matches?(route.verb, request.request_method)

        path_params = path_params_for(route.path, request.path)
        return Route.new(verb: route.verb, path: route.path, controller: route.controller, params: path_params) if path_params

        false
      end
    end

    def match?(request, controller_prefix:)
      find(request, controller_prefix: controller_prefix).present?
    end

    # Generic SPA-route existence check used by wildcard host routes (e.g.
    # "admin/*path", "repositories/:repository_id/plugin/*path") to decide
    # whether some plugin declared a matching `spa#show` route, instead of
    # 404ing a plugin page on hard reload/direct navigation. Unlike #find,
    # this only checks path shape (params can include dynamic segments like
    # ":repository_id"), not an HTTP verb, since spa#show is always GET.
    def spa_route_declared?(path)
      plugin_routes.any? do |route|
        # path_params_for returns {} (falsy-looking but truthy) for a static
        # match with no dynamic segments — check truthiness, not #present?,
        # since {}.present? is false.
        route.controller == "spa#show" && !!path_params_for(route.path, path)
      end
    end

    private

    def plugin_routes
      Syrus::PluginRegistry.all_plugins.flat_map do |manifest|
        metadata = manifest.metadata.with_indifferent_access
        Array(metadata[:routes]).filter_map do |raw_route|
          route = raw_route.to_h.with_indifferent_access
          next if route[:controller].blank? || route[:path].blank?

          Route.new(
            verb: route[:verb].presence || "GET",
            path: route[:path].to_s,
            controller: route[:controller].to_s,
            params: {}
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
