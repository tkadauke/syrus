module Api
  module V1
    module App
      class ThemeController < BaseController
        # Rails' ActionController::ParamsWrapper wraps JSON request bodies
        # under a key matching the controller name ("theme") using the
        # `Theme` model's own column list -- which has no `color_theme_id`
        # column (that belongs to User). A JSON PATCH with only
        # `color_theme_id` in the body then gets a spurious empty
        # `params[:theme] == {}` injected, which update_attributes below
        # would otherwise forward straight into `User#theme` and fail its
        # presence/inclusion validation. This controller's params are flat,
        # not a nested resource payload, so disable wrapping entirely.
        wrap_parameters false

        def update
          unless color_theme_param_selectable?
            render_error("validation_failed", "color theme is not available", status: :unprocessable_content)
            return
          end

          if Current.user.update(update_attributes)
            render json: theme_payload
          else
            render_error("validation_failed", Current.user.errors.full_messages.to_sentence,
                         status: :unprocessable_content)
          end
        end

        private

        def update_attributes
          attrs = {}
          attrs[:theme] = params[:theme] if params.key?(:theme)
          attrs[:color_theme_id] = params[:color_theme_id].presence if params.key?(:color_theme_id)
          attrs
        end

        def color_theme_param_selectable?
          return true unless params.key?(:color_theme_id)

          id = params[:color_theme_id].presence
          return true if id.nil?

          Theme.selectable_by(Current.user).exists?(id: id)
        end

        def theme_payload
          Current.user.reload
          {
            theme: Current.user.theme,
            color_theme_id: Current.user.color_theme_id,
            color_theme: Current.user.color_theme&.public_payload
          }
        end
      end
    end
  end
end
