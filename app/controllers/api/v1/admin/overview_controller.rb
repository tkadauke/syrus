module Api
  module V1
    module Admin
      # Token-auth admin diagnostics API. The app API uses the same
      # OverviewPayload and Admin::StuckItems source as the React UI
      # so the surfaces can't drift.
      #
      #   GET /api/v1/admin/overview → tile-shaped rollup
      #   GET /api/v1/admin/stuck    → full StuckItems list
      class OverviewController < BaseController
        def show
          render json: ::Admin::OverviewPayload.new(params: params).as_json
        end

        def stuck
          render json: ::Admin::OverviewPayload.new(params: params).stuck_json
        end
      end
    end
  end
end
