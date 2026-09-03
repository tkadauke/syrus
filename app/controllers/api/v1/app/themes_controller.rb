module Api
  module V1
    module App
      class ThemesController < BaseController
        def index
          themes = Theme.selectable_by(Current.user).order(built_in: :desc, position: :asc, name: :asc)
          render json: { themes: themes.map(&:public_payload) }
        end

        def create
          theme = Theme.new(
            name: theme_attributes[:name],
            slug: unique_slug_for(theme_attributes[:name]),
            owner_user: Current.user,
            built_in: false,
            position: next_position,
            tokens: normalized_tokens(theme_attributes)
          )

          return render_contrast_errors(theme, action: "installing") if theme.contrast_issues.any?

          if theme.save
            render json: { theme: theme.public_payload }, status: :created
          else
            render_error("validation_failed", theme.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        # Scoped to selectable_by so a user can't fetch another user's
        # custom (non-built-in) theme by guessing its id — same visibility
        # rule as #index, just for a single row (e.g. the Style Guide
        # page's ?theme_id= preview).
        def show
          theme = Theme.selectable_by(Current.user).find(params[:id])
          render json: { theme: theme.public_payload }
        end

        def update
          theme = editable_themes.find(params[:id])
          theme.name = theme_attributes[:name] if theme_attributes[:name].present?
          theme.tokens = merged_tokens(theme, theme_attributes) if token_update?(theme_attributes)

          return render_contrast_errors(theme, action: "saving") if theme.contrast_issues.any?

          if theme.save
            render json: { theme: theme.public_payload }
          else
            render_error("validation_failed", theme.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def destroy
          theme = editable_themes.find(params[:id])
          fallback = nil

          if Current.user.color_theme_id == theme.id
            fallback = Theme.terracotta
            Current.user.update!(color_theme: fallback)
          end

          theme.destroy!
          render json: { deleted_theme_id: theme.id, fallback_theme_id: fallback&.id }
        end

        def reorder
          raw_ids = params[:ids]
          unless raw_ids.is_a?(Array) && raw_ids.any?
            render_error("validation_failed", "ids is required.", status: :unprocessable_content)
            return
          end

          ids = raw_ids.map { |id| Integer(id, exception: false) }
          if ids.any?(&:nil?)
            render_error("validation_failed", "ids must contain only integers.", status: :unprocessable_content)
            return
          end

          if ids.uniq.size != ids.size
            render_error("validation_failed", "ids must not contain duplicates.", status: :unprocessable_content)
            return
          end

          themes_by_id = editable_themes.where(id: ids).index_by(&:id)
          if themes_by_id.size != ids.size
            render_error("not_found", "One or more themes were not found.", status: :not_found)
            return
          end

          ordered_themes = ids.map { |id| themes_by_id.fetch(id) }
          remaining_themes = editable_themes.where.not(id: ids).order(:position, :name, :id)

          Theme.transaction do
            (ordered_themes + remaining_themes).each_with_index do |theme, position|
              theme.update_columns(position: position, updated_at: Time.current)
            end
          end

          render json: { themes: editable_themes.order(:position, :name, :id).map(&:public_payload) }
        end

        private

        def editable_themes
          Theme.owned_custom_by(Current.user)
        end

        def theme_attributes
          @theme_attributes ||= begin
            source = params[:theme].is_a?(ActionController::Parameters) ? params[:theme] : params
            plain_json(source).with_indifferent_access
          end
        end

        def normalized_tokens(attributes)
          token_payload = attributes[:tokens].presence || {
            "light" => attributes[:light],
            "dark" => attributes[:dark]
          }
          raw_payload = plain_json(token_payload)
          payload = raw_payload.is_a?(Hash) ? raw_payload.with_indifferent_access : {}
          payload.slice(:light, :dark).transform_values do |value|
            value.is_a?(Hash) ? plain_json(value).stringify_keys : value
          end
        end

        def token_update?(attributes)
          attributes.key?(:tokens) || attributes.key?(:light) || attributes.key?(:dark)
        end

        def merged_tokens(theme, attributes)
          overrides = normalized_tokens(attributes)
          {
            "light" => merge_mode_tokens(theme.tokens["light"], overrides[:light]),
            "dark" => merge_mode_tokens(theme.tokens["dark"], overrides[:dark])
          }
        end

        def merge_mode_tokens(existing, overrides)
          base = existing || {}
          supplied = (overrides || {}).stringify_keys
          Theme::TOKEN_KEYS.index_with { |key| supplied[key].presence || base[key] }.compact
        end

        def next_position
          (editable_themes.maximum(:position) || -1) + 1
        end

        def unique_slug_for(name)
          base = name.to_s.parameterize.presence || "theme"
          candidate = "#{base}-#{Current.user.id}"
          suffix = 1
          while Theme.exists?(slug: candidate)
            suffix += 1
            candidate = "#{base}-#{Current.user.id}-#{suffix}"
          end
          candidate
        end

        def render_contrast_errors(theme, action:)
          issues = theme.contrast_issues
          render json: {
            error: {
              code: "contrast_check_failed",
              message: "Contrast check failed -- fix these before #{action}: #{issues.map { |issue| issue.fetch(:message) }.join('; ')}.",
              issues: issues
            }
          }, status: :unprocessable_content
        end
      end
    end
  end
end
