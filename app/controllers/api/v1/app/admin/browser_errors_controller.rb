module Api
  module V1
    module App
      module Admin
        class BrowserErrorsController < BaseController
          def index
            render json: ::Admin::BrowserErrorEventsPayload.new(params: params).as_json
          rescue ArgumentError => e
            render_error("invalid_browser_error_search", e.message, status: :unprocessable_content)
          end

          def controls
            render json: ::Admin::BrowserErrorEventsPayload.new(params: params).controls_json
          end

          def show
            render json: ::Admin::BrowserErrorEventsPayload.new(params: params).detail_json(params[:id])
          end
        end
      end
    end
  end
end
