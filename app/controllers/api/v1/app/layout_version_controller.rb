module Api
  module V1
    module App
      class LayoutVersionController < BaseController
        def update
          if Current.user.update(layout_version: params.require(:layout_version))
            render json: { layout_version: Current.user.layout_version }
          else
            render_error("validation_failed", Current.user.errors.full_messages.to_sentence,
                         status: :unprocessable_content)
          end
        end
      end
    end
  end
end
