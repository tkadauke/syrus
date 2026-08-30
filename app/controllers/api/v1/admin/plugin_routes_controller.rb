module Api
  module V1
    module Admin
      class PluginRoutesController < BaseController
        include PluginRouteDispatch

        def show
          route = PluginRouteResolver.find(request, controller_prefix: "api/v1/admin/")
          unless route
            disabled_route = PluginRouteResolver.find_disabled(request, controller_prefix: "api/v1/admin/")
            if disabled_route
              return render_error("plugin_disabled", "The #{disabled_route.plugin_name} plugin is disabled.", status: :not_found)
            end

            return render_error("not_found", "Plugin route not found", status: :not_found)
          end

          dispatch_plugin_route!(route)
        end
      end
    end
  end
end
