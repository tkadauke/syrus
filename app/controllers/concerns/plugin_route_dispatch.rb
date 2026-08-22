module PluginRouteDispatch
  extend ActiveSupport::Concern

  private

  def dispatch_plugin_route!(route)
    controller_path, action_name = route.controller.split("#", 2)
    raise ActionController::RoutingError, "Invalid plugin route target" if controller_path.blank? || action_name.blank?

    controller_class = "#{controller_path.camelize}Controller".constantize
    raise ActionController::RoutingError, "Invalid plugin route controller" unless controller_class < ActionController::Metal

    request.path_parameters.merge!(route.params)
    request.path_parameters.delete(:plugin_route)
    # #params memoizes into this header on first access; PluginRoutesController's
    # own before_actions (auth/session resume) already read params before we
    # get here, so without clearing it the redispatched controller would see
    # the stale pre-merge path_parameters (missing any dynamic segments the
    # matched route declared, e.g. :repository_id) instead of route.params.
    request.delete_header("action_dispatch.request.parameters")

    controller_class.dispatch(action_name, request, response)
  end
end
