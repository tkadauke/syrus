module Api
  module V1
    module App
      class ThemeController < BaseController
        def update
          if Current.user.update(theme: params.require(:theme))
            render json: { theme: Current.user.theme }
          else
            render_error("validation_failed", Current.user.errors.full_messages.to_sentence,
                         status: :unprocessable_content)
          end
        end
      end
    end
  end
end
