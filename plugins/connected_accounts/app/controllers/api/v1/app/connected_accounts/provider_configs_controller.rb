module Api::V1::App::ConnectedAccounts
  class ProviderConfigsController < Api::V1::App::Admin::BaseController
    def show
      render json: { provider_config: serialized(config) }
    end

    def update
      config.assign_attributes(config_params)
      config.provider_key = "generic_oauth2"
      if config.save
        render json: { provider_config: serialized(config), message: I18n.t("connected_accounts.settings.saved") }
      else
        render_error("validation_failed", config.errors.full_messages.to_sentence, status: :unprocessable_content)
      end
    end

    private

    def config = @config ||= ::ConnectedAccounts::ProviderConfig.find_or_initialize_by(provider_key: "generic_oauth2")
    def config_params
      permitted = params.require(:provider_config).permit(:authorize_url, :token_url, :revoke_url, :identity_url, :validate_url, :client_id, :client_secret, scope_catalog: [], api_origins: [])
      permitted.delete(:client_secret) if permitted[:client_secret].blank?
      permitted
    end
    def serialized(value)
      value.as_json(only: %i[authorize_url token_url revoke_url identity_url validate_url client_id scope_catalog api_origins]).merge(client_secret_configured: value.client_secret.present?)
    end
  end
end
