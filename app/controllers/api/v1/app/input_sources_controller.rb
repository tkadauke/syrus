module Api
  module V1
    module App
      class InputSourcesController < BaseController
        def linear_show
          repository = find_repository
          source = repository.linear_input_source
          render json: { linear_source: linear_source_json(source) }
        end

        def linear_update
          repository = find_repository
          source = repository.linear_input_source ||
                   InputSources::Linear.new(repository: repository, user: Current.user)

          attrs = linear_source_params
          api_key = attrs[:api_key].presence

          source.polling_enabled = ActiveModel::Type::Boolean.new.cast(attrs[:polling_enabled])
          source.config = source.config.merge(
            "team_id" => attrs[:team_id].to_s.strip,
            "label_filter" => attrs[:label_filter].to_s.strip.presence
          ).compact

          if api_key
            source.credentials = (source.credentials || {}).merge("api_key" => api_key)
          end

          begin
            source.validate_credentials!
          rescue => e
            render_error("validation_failed", e.message, status: :unprocessable_content)
            return
          end

          if source.save
            render json: {
              linear_source: linear_source_json(source),
              message: I18n.t("api.input_sources.linear_saved")
            }
          else
            render_error("validation_failed", source.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        private

        def find_repository
          Current.user.repositories.find(params[:repository_id])
        end

        def linear_source_json(source)
          return nil unless source

          {
            id: source.id,
            polling_enabled: source.polling_enabled?,
            team_id: source.config["team_id"].to_s,
            label_filter: source.config["label_filter"].to_s,
            last_poll_started_at: source.repository.last_poll_started_at&.iso8601,
            issues_ingested_count: source.issues_ingested_count
          }
        end

        def linear_source_params
          params.require(:linear_source).permit(:api_key, :team_id, :label_filter, :polling_enabled)
        end
      end
    end
  end
end
