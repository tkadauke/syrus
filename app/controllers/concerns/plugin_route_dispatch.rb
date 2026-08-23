module PluginRouteDispatch
  extend ActiveSupport::Concern

  private

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

    controller_class.dispatch(action_name, request, response)
  end
end
