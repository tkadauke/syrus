class SlugRedirectsController < ApplicationController
  def show
    resolution = SlugRefs::Resolver.resolve(params[:slug], user: Current.user)

    unless resolution.accessible?
      head :not_found
      return
    end

    redirect_to resolution.to_h.fetch(:web_path)
  end
end
