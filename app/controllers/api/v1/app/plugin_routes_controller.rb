module Api
  module V1
    module App
      class PluginRoutesController < BaseController
        include PluginRouteDispatch

        def show
          dispatch_plugin_route_for!(controller_prefix: "api/v1/app/")
        end
      end
    end
  end
end
