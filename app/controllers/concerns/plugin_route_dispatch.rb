module PluginRouteDispatch
  extend ActiveSupport::Concern

  DISPATCHED_ROUTE_ENV_KEY = "syrus.plugin_route_dispatch.dispatched".freeze

  private

  LEGACY_PLUGIN_DISABLED_CODES = {
    "syrus_dev" => "syrus_dev_plugin_disabled",
    "tailscale" => "tailscale_plugin_disabled"
  }.freeze

  def legacy_plugin_disabled_code(plugin_name)
    LEGACY_PLUGIN_DISABLED_CODES[plugin_name]
  end

  def render_legacy_plugin_disabled(plugin_name)
    render json: { error: legacy_plugin_disabled_code(plugin_name) }, status: :not_found
  end

  def dispatch_plugin_route_for!(controller_prefix:)
    route = PluginRouteResolver.find(request, controller_prefix: controller_prefix)
    return dispatch_plugin_route!(route) if route

    disabled_route = PluginRouteResolver.find_disabled(request, controller_prefix: controller_prefix)
    if disabled_route
      return render_legacy_plugin_disabled(disabled_route.plugin_name) if legacy_plugin_disabled_code(disabled_route.plugin_name)

      return render_error("plugin_disabled", I18n.t("api.plugins.disabled", plugin: disabled_route.plugin_name), status: :not_found)
    end

    render_error("not_found", I18n.t("api.plugins.route_not_found"), status: :not_found)
  end

  def dispatch_plugin_route!(route)
    controller_path, action_name = route.controller.split("#", 2)
    raise ActionController::RoutingError, "Invalid plugin route target" if controller_path.blank? || action_name.blank?

    controller_class = "#{controller_path.camelize}Controller".constantize
    raise ActionController::RoutingError, "Invalid plugin route controller" unless controller_class < ActionController::Metal

    # Use the path_parameters= setter, not an in-place mutation of the hash
    # path_parameters returns. Rails memoizes request.params (GET+POST+path)
    # into an env key on first access -- middleware ahead of us in the stack
    # (request logging, etc.) routinely triggers that memoization before we
    # get here. Only the setter invalidates it; merge!-ing the returned hash
    # leaves the memo stale, so route.params (:id, :chat_id, ...) would be
    # missing from the dispatched controller's `params` even though
    # request.path_parameters itself looks correct.
    request.path_parameters = request.path_parameters.merge(route.params).except(:plugin_route)

    request.env[DISPATCHED_ROUTE_ENV_KEY] = true
    controller_class.dispatch(action_name, request, response)
  end
end
