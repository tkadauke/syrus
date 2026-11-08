module Api
  module V1
    module App
      class SidebarPagesController < BaseController
        def index
          payload = ::App::SidebarPagesPayload.new.as_json
          fresh_when(etag: payload, public: false)
          render json: payload unless performed?
        end
      end
    end
  end
end
