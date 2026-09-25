module Api
  module V1
    module App
      class ReviewDiffSettingsController < BaseController
        def show
          render json: settings_payload
        end

        def update
          settings = review_diff_settings_params
          if settings.empty?
            render_error("validation_failed", "Choose at least one review setting.", status: :unprocessable_content)
            return
          end

          Current.user.update_review_diff_settings!(settings)

          render json: settings_payload.merge(message: "Review settings updated.")
        end

        private

        def settings_payload
          {
            review_diff_settings: Current.user.reload.review_diff_settings
          }
        end

        def review_diff_settings_params
          source = params[:review_diff_settings].presence || params
          source.permit(*ReviewDiffSettings.permitted_keys).to_h
        end
      end
    end
  end
end
