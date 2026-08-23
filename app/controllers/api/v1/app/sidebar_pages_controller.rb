module Api
  module V1
    module App
      class SidebarPagesController < BaseController
        def index
          render json: ::App::SidebarPagesPayload.new.as_json
        end
      end
    end
  end
end
