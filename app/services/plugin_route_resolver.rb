class PluginRouteResolver
  Route = Data.define(:verb, :path, :controller, :params, :plugin_name, :enabled)
  ROUTE_CACHE_MUTEX = Mutex.new

  # What an `:id`/`:*_id` sidebar path segment is allowed to look like: a bare
  # Rails id, or a "PREFIX-<digits>" slug like "MOCKUP-1"/"DOC-2" (the same
  # shape Job/Epic detail routes already accept via their own hand-written
  # `constraints: { id: /[a-zA-Z0-9_-]+/ }`). Deliberately not open alnum, so a
  # static segment like "scheduled_tasks/legacy" still can't slip through as a
  # match for "/scheduled_tasks/:id" -- see #sidebar_path_matches?.
  ID_SEGMENT_SOURCE = '\d+|[A-Za-z]+-\d+'.freeze

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
      all_plugin_routes.select { |route| enabled.nil? || route.enabled == enabled }
    end

    def all_plugin_routes
      generation = Syrus::PluginRegistry.generation
      return @plugin_routes if @plugin_routes_generation == generation

      ROUTE_CACHE_MUTEX.synchronize do
        generation = Syrus::PluginRegistry.generation
        return @plugin_routes if @plugin_routes_generation == generation

        @plugin_routes = build_plugin_routes.freeze
        @plugin_routes_generation = generation
        @plugin_routes
      end
    end

    def build_plugin_routes
      Syrus::PluginRegistry.all_plugins.flat_map do |manifest|
        Array(manifest.metadata.with_indifferent_access[:routes]).filter_map do |raw_route|
          attributes = raw_route.to_h.with_indifferent_access
          next if attributes[:controller].blank? || attributes[:path].blank?

          Route.new(
            verb: attributes[:verb].presence || "GET",
            path: attributes[:path].to_s,
            controller: attributes[:controller].to_s,
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
