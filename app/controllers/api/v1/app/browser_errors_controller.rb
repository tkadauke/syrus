module Api
  module V1
    module App
      class BrowserErrorsController < BaseController
        def create
          event = BrowserErrorEvent.record!(user: Current.user, payload: browser_error_params)
          render json: { id: event.id, fingerprint: event.fingerprint }, status: :created
        end

        private

        def browser_error_params
          plain_json(params.require(:browser_error))
        end
      end
    end
  end
end
