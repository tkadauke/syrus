module Api
  module V1
    module App
      module Admin
        class WorkflowActivityController < BaseController
          def index
            return unless stale?(etag: [ WorkflowActivityEvent.maximum(:id), request.query_parameters ])

            render json: ::Admin::WorkflowActivityPayload.new(params: params).as_json
          end
        end
      end
    end
  end
end
