module Api
  module V1
    module App
      module Admin
        class StuckController < BaseController
          def index
            snapshot = ::Admin::StuckItemsCache.read
            return unless stale?(etag: [ snapshot.captured_at, params[:page], params[:q], params[:sort], params[:direction], params[:include_diagnostics] ])

            render json: ::Admin::OverviewPayload.new(params: params).stuck_json
          end
        end
      end
    end
  end
end
