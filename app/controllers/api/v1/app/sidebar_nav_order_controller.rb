module Api
  module V1
    module App
      class SidebarNavOrderController < BaseController
        def update
          Current.user.update_sidebar_nav_order!(Array(params[:order]))
          render json: { sidebar_nav_order: Current.user.sidebar_nav_order }
        end
      end
    end
  end
end
