module Api
  module V1
    module App
      class LinearController < BaseController
        def teams
          api_key = params[:api_key].to_s.strip
          return render_error("invalid_request", "api_key is required", status: :unprocessable_content) if api_key.blank?

          client = LinearClient.new(api_key: api_key)
          render json: { teams: client.teams }
        rescue => e
          render_error("api_error", e.message, status: :unprocessable_content)
        end
      end
    end
  end
end
