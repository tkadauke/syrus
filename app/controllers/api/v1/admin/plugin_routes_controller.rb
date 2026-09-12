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
              return render_legacy_plugin_disabled(disabled_route.plugin_name) if legacy_plugin_disabled_code(disabled_route.plugin_name)

              return render_error("plugin_disabled", I18n.t("api.plugins.disabled", plugin: disabled_route.plugin_name), status: :not_found)
            end

            return render_error("not_found", I18n.t("api.plugins.route_not_found"), status: :not_found)
          end

          dispatch_plugin_route!(route)
        end
      end
    end
  end
end
