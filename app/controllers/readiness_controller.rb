class ReadinessController < ActionController::API
  def show
    payload = AppApi::ReadinessChecks.new.as_json
    status = payload[:status] == "error" ? :service_unavailable : :ok
    render json: payload, status: status
  end
end
