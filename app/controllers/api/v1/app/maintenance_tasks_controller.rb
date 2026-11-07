module Api
  module V1
    module App
      class MaintenanceTasksController < BaseController
        def sidebar
          return render json: { tasks: [] } unless Current.user&.admin?

          payload = ::App::MaintenanceTasksPayload.sidebar
          fresh_when(etag: payload, public: false)
          render json: payload unless performed?
        end
      end
    end
  end
end
