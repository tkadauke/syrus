module Api
  module V1
    module Admin
      class TailscaleController < BaseController
        def status
          return render json: { error: "tailscale_plugin_disabled" }, status: :not_found unless Tailscale.enabled?

          render json: Tailscale::StatusPayload.call
        end
      end
    end
  end
end
