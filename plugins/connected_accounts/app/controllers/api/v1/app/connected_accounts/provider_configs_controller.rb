module Api::V1::App::ConnectedAccounts
  class ProviderConfigsController < Api::V1::App::Admin::BaseController
    def show
      render json: { provider_config: serialized(provider_config) }
    end

    def update
      provider_config.assign_attributes(config_params)
      provider_config.provider_key = "generic_oauth2"
      if provider_config.save
        render json: { provider_config: serialized(provider_config), message: I18n.t("connected_accounts.settings.saved") }
      else
        render_error("validation_failed", provider_config.errors.full_messages.to_sentence, status: :unprocessable_content)
      end
    end

    private

    def provider_config = @provider_config ||= ::ConnectedAccounts::ProviderConfig.find_or_initialize_by(provider_key: "generic_oauth2")
    def config_params
      permitted = params.require(:provider_config).permit(:authorize_url, :token_url, :revoke_url, :identity_url, :validate_url, :client_id, :client_secret,
        scope_catalog: [], read_only_scopes: [], api_origins: [])
      permitted.delete(:client_secret) if permitted[:client_secret].blank?
      permitted
    end
    def serialized(value)
      value.as_json(only: %i[authorize_url token_url revoke_url identity_url validate_url client_id scope_catalog read_only_scopes api_origins])
        .merge(client_secret_configured: value.client_secret.present?)
    end
  end
end
