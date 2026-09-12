module Api
  module V1
    module App
      class MaintenanceTasksController < BaseController
        def sidebar
          return render json: { tasks: [] } unless Current.user&.admin?

          render json: ::App::MaintenanceTasksPayload.sidebar
        end
      end
    end
  end
end
