module Api
  module V1
    module App
      class ToursController < BaseController
        def dismiss
          tour_id = params.require(:tour_id).to_s.strip
          if tour_id.blank?
            render_error("validation_failed", "tour_id is required", status: :unprocessable_content)
            return
          end

          Current.user.mark_tour_seen(tour_id)
          render json: { seen_tours: Current.user.seen_tours }
        end

        def reset
          Current.user.reset_tours!
          render json: { seen_tours: [] }
        end
      end
    end
  end
end
