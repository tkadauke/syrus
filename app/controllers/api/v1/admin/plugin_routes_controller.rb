module Api
  module V1
    module Admin
      class PluginRoutesController < BaseController
        include PluginRouteDispatch

        def show
          dispatch_plugin_route_for!(controller_prefix: "api/v1/admin/")
        end
      end
    end
  end
end
