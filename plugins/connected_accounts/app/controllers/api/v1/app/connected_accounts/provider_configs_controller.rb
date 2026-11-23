module Api::V1::App::ConnectedAccounts
  class ProviderConfigsController < Api::V1::App::Admin::BaseController
    def index
      render json: { providers: configurable_providers.map { |item| serialized(config_for(item.key), declaration: item) } }
    end

    def show
      render json: { provider_config: serialized(provider_config, declaration:) }
    end

    def update
      provider_config.assign_attributes(config_params)
      provider_config.provider_key = declaration.key
      provider_config.assign_attributes(managed_configuration)
      if provider_config.save
        render json: { provider_config: serialized(provider_config, declaration:), message: I18n.t("connected_accounts.settings.saved") }
      else
        render_error("validation_failed", provider_config.errors.full_messages.to_sentence, status: :unprocessable_content)
      end
    end

    private

    def declaration
      @declaration ||= configurable_providers.find { |item| item.key == params.fetch(:provider, "generic_oauth2") } || raise(ActiveRecord::RecordNotFound)
    end
    def configurable_providers = ::ConnectedAccounts::ProviderRegistry.all.reject { |item| item.key == "fake" }
    def config_for(key)
      value = ::ConnectedAccounts::ProviderConfig.find_or_initialize_by(provider_key: key)
      item = configurable_providers.find { |provider| provider.key == key }
      value.assign_attributes(item.configuration.except("managed")) if value.new_record? && item&.configuration&.fetch("managed", false)
      value
    end
    def managed_configuration
      declaration.configuration.fetch("managed", false) ? declaration.configuration.except("managed") : {}
    end
    def provider_config = @provider_config ||= config_for(declaration.key)
    def config_params
      permitted = params.require(:provider_config).permit(:authorize_url, :token_url, :revoke_url, :identity_url, :validate_url, :client_id, :client_secret, :allow_as_owner,
        scope_catalog: [], read_only_scopes: [], api_origins: [])
      permitted.delete(:client_secret) if permitted[:client_secret].blank?
      permitted
    end
    def serialized(value, declaration:)
      value.as_json(only: %i[authorize_url token_url revoke_url identity_url validate_url client_id scope_catalog read_only_scopes api_origins allow_as_owner])
        .merge(provider_key: declaration.key, display_name: declaration.display_name,
          managed_settings: declaration.configuration.fetch("managed", false), client_secret_configured: value.client_secret.present?,
          settings_notice: declaration.settings_notice, settings_notice_i18n_key: declaration.settings_notice_i18n_key)
    end
  end
end
