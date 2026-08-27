module Api
  module V1
    module App
      class ThemesController < BaseController
        def index
          themes = Theme.selectable_by(Current.user).order(built_in: :desc, name: :asc)
          render json: { themes: themes.map(&:public_payload) }
        end
      end
    end
  end
end
