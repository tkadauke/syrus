module Api
  module V1
    module App
      module Admin
        class StuckController < BaseController
          def index
            payload = ::Admin::OverviewPayload.new(params: params)
            snapshot = payload.stuck_snapshot
            return unless stale?(etag: [ snapshot.captured_at, params[:page], params[:q], params[:sort], params[:direction], params[:include_diagnostics] ])

            render json: payload.stuck_json(snapshot: snapshot)
          end
        end
      end
    end
  end
end
