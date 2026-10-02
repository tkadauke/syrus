module Api
  module V1
    module App
      class SlugRefsController < BaseController
        def show
          resolution = SlugRefs::Resolver.resolve(params[:slug], user: Current.user)

          if resolution.unknown?
            render_error("not_found", "Slug reference not found.", status: :not_found)
            return
          end

          if resolution.malformed?
            render_error("bad_request", "Slug reference is malformed.", status: :bad_request)
            return
          end

          render json: { slug_ref: resolution.to_h }
        end
      end
    end
  end
end
