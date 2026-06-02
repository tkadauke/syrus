module Api
  module V1
    module App
      class SetupController < BaseController
        def show
          render json: ::App::SetupStatus.call(user: Current.user)
        end
      end
    end
  end
end
