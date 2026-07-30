module Api
  module V1
    module App
      class InputSourcesController < BaseController
        def show
          repository = find_repository
          provider = find_provider
          source = source_for(repository, provider)

          render json: { input_source: input_source_json(source, provider) }
        end

        def update
          repository = find_repository
          provider = find_provider
          source = source_for(repository, provider) ||
                   provider.new(repository: repository, user: Current.user)

          attrs = input_source_params
          source.polling_enabled = ActiveModel::Type::Boolean.new.cast(attrs[:polling_enabled])

          config_updates, credential_updates = schema_updates(provider, attrs[:values] || {})
          source.config = (source.config || {}).merge(config_updates).compact
          source.credentials = (source.credentials || {}).merge(credential_updates) if credential_updates.any?

          begin
            source.validate_credentials!
          rescue => e
            render_error("validation_failed", e.message, status: :unprocessable_content)
            return
          end

          if source.save
            render json: {
              input_source: input_source_json(source, provider),
              message: I18n.t("api.input_sources.saved", source: source_label(provider))
            }
          else
            render_error("validation_failed", source.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        private

        def find_repository
          Current.user.repositories.find(params[:repository_id])
        end

        def find_provider
          provider = available_input_source_providers.find { |klass| source_type_key(klass) == params[:type].to_s }
          raise ActiveRecord::RecordNotFound, "Unknown input source type" unless provider

          provider
        end

        def available_input_source_providers
          Syrus::PluginRegistry.providers_for(:input_source)
        end

        def source_for(repository, provider)
          repository.input_sources.find_by(type: provider.name)
        end

        def input_source_json(source, provider = source.class)
          return nil unless source

          values = source.config.to_h.merge(credential_placeholders(source, provider))
          {
            id: source.id,
            type: provider.name,
            type_key: source_type_key(provider),
            label: source_label(provider),
            polling_enabled: source.polling_enabled?,
            values: values,
            last_poll_started_at: source.repository.last_poll_started_at&.iso8601,
            issues_ingested_count: source.respond_to?(:issues_ingested_count) ? source.issues_ingested_count : Job.where(input_source_id: source.id).count
          }
        end

        def input_source_params
          params.require(:input_source).permit(:polling_enabled, values: {})
        end

        def schema_updates(provider, values)
          schema = provider.new.config_schema
          config_updates = {}
          credential_updates = {}

          schema.each do |field|
            key = field.fetch(:key).to_s
            next unless values.key?(key)

            value = values[key].to_s.strip
            if credential_field?(field)
              credential_updates[key] = value if value.present?
            else
              config_updates[key] = value.presence
            end
          end

          [ config_updates, credential_updates ]
        end

        def credential_placeholders(source, provider)
          provider.new.config_schema.each_with_object({}) do |field, values|
            next unless credential_field?(field)

            key = field.fetch(:key).to_s
            values[key] = source.credentials.to_h[key].present? ? "" : nil
          end
        end

        def credential_field?(field)
          field[:scope].to_s == "credentials"
        end

        def source_type_key(provider)
          provider.name.demodulize.underscore
        end

        def source_label(provider)
          provider.name.demodulize
        end
      end
    end
  end
end
