module Api
  module V1
    module App
      class ThemesController < BaseController
        def index
          themes = Theme.selectable_by(Current.user).order(built_in: :desc, name: :asc)
          render json: { themes: themes.map(&:public_payload) }
        end

        # Scoped to selectable_by so a user can't fetch another user's
        # custom (non-built-in) theme by guessing its id — same visibility
        # rule as #index, just for a single row (e.g. the Style Guide
        # page's ?theme_id= preview).
        def show
          theme = Theme.selectable_by(Current.user).find(params[:id])
          render json: { theme: theme.public_payload }
        end
      end
    end
  end
end
