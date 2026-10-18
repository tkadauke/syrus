module Api
  module V1
    module App
      class SlugRefsController < BaseController
        def show
          resolution = SlugRefs::Resolver.resolve(params[:slug], user: Current.user)
          resolution = invocation_scoped_resolution(resolution)

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

        private

        def invocation_scoped_resolution(resolution)
          return resolution unless resolution.accessible?
          return resolution unless resolution.record.is_a?(ApplicationRecord)

          relation = resolution.record.class.where(id: resolution.record.id)
          return resolution if restrict_invocation_relation(relation).exists?

          SlugRefs::Resolution.inaccessible(provider: resolution.provider, id: resolution.numeric_id)
        end
      end
    end
  end
end
