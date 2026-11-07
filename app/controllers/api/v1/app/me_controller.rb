module Api
  module V1
    module App
      class MeController < BaseController
        def show
          render json: AppApi::MeSerializer.new(user: Current.user).as_json
        end
      end
    end
  end
end
