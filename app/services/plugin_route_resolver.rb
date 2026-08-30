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

    # Generic SPA-route existence check used by wildcard host routes (e.g.
    # "admin/*path", "repositories/:repository_id/plugin/*path") to decide
    # whether some plugin declared a matching `spa#show` route, instead of
    # 404ing a plugin page on hard reload/direct navigation. Unlike #find,
    # this only checks path shape (params can include dynamic segments like
    # ":repository_id"), not an HTTP verb, since spa#show is always GET.
    def spa_route_declared?(path)
      plugin_routes(enabled: true).any? do |route|
        # path_params_for returns {} (falsy-looking but truthy) for a static
        # match with no dynamic segments — check truthiness, not #present?,
        # since {}.present? is false.
        route.controller == "spa#show" && !!path_params_for(route.path, path)
      end
    end

    # Structural companion to #spa_route_declared? for the
    # "repositories/:repository_id/plugin/*path" host route. A repo_page_tab
    # provider's own repo_page_tabs(repository:, user:) already returns the
    # canonical "/repositories/#{repository.id}/plugin/<tab_key>" path for
    # each tab it exposes, so this derives valid SPA paths straight from that
    # metadata instead of requiring every repo_page_tab plugin to hand-declare
    # a redundant spa#show manifest route (the bug class behind the git_history
    # Git History tab 404ing on hard reload — the very first plugin built
    # against this extension point forgot the manual declaration).
    #
    # Repository access is intentionally NOT viewer-scoped here: like every
    # other SPA-shell route, this only decides whether Rails should serve the
    # SPA shell at all versus a bare 404 — real per-viewer authorization is
    # enforced by the authenticated API calls the SPA makes after it mounts
    # (see SpaController, which has no repository-level gating either). So the
    # tab list is computed using any user known to have access to the
    # repository (its owner, or else any member), not the requesting user.
    def repo_page_tab_route?(path)
      match = REPO_PAGE_TAB_PATH.match(path)
      return false unless match

      repository = Repository.find_by(id: match[:repository_id])
      return false unless repository

      probe_user = repository.user || repository.repository_memberships.first&.user
      return false unless probe_user

      Repositories::PluginRepoTabsPayload.tabs_for(repository: repository, user: probe_user).any? do |tab|
        Array(tab[:paths]).include?(path)
      end
    end

    private

    REPO_PAGE_TAB_PATH = %r{\A/repositories/(?<repository_id>\d+)/plugin/}

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
