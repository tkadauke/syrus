module Api
  module V1
    module App
      module Admin
        class ReconcilerActivityController < BaseController
          def index
            return unless stale?(etag: [ WorkEngineReconcilerActivityEvent.maximum(:id), request.query_parameters ])

            render json: ::Admin::ReconcilerActivityPayload.new(params: params).as_json
          end
        end
      end
    end
  end
end
