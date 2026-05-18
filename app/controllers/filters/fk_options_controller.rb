class ::Filters::FkOptionsController < ApplicationController
  allow_unauthenticated_access
  before_action :resume_session
  before_action :require_json_authentication

  def index
    resolver = ::Filters::FkOptionsResolver.new(user: Current.user)
    render json: resolver.resolve(field: params[:field], q: params[:q], ids: params[:ids])
  rescue ::Filters::FkOptionsResolver::UnknownField
    render json: { error: "unknown field" }, status: :bad_request
  end

  private

  def require_json_authentication
    return if Current.user

    render json: { error: "unauthorized" }, status: :unauthorized
  end
end
