module Api
  module V1
    module App
      module Admin
        class ConnectedAccountProvidersController < BaseController
          def index
            render json: { providers: ::ConnectedAccounts::ProviderConfig.order(:display_name).map { |config| serialize(config) } }
          end

          def create
            attributes = provider_params
            config = ApplicationRecord.transaction do
              credential = ::ConnectedAccounts::CredentialMaterial.store_client!(user: Current.user, key: attributes[:key],
                client_id: params.require(:client_id), client_secret: params.require(:client_secret))
              ::ConnectedAccounts::ProviderConfig.create!(attributes.merge(created_by: Current.user,
                credential_store_credential: credential))
            end
            render json: { provider: serialize(config) }, status: :created
          rescue ActiveRecord::RecordInvalid => error
            render_error("validation_failed", error.record.errors.full_messages.to_sentence, status: :unprocessable_content)
          end

          def destroy
            config = ::ConnectedAccounts::ProviderConfig.find(params[:id])
            if ::ConnectedAccounts::Account.where(provider: config.key).where.not(status: "revoked").exists?
              return render_error("provider_in_use", "Disconnect active accounts before deleting this provider.", status: :conflict)
            end
            ::ConnectedAccounts::CredentialMaterial.erase!(config.credential_store_credential, user: Current.user)
            config.destroy!
            head :no_content
          end

          private

          def provider_params
            params.permit(:key, :display_name, :authorize_url, :token_url, :revoke_url, :identity_url,
              scopes: [], api_origins: []).to_h.symbolize_keys
          end

          def serialize(config)
            config.slice(:id, :key, :display_name, :authorize_url, :token_url, :revoke_url,
              :identity_url, :scopes, :api_origins, :created_at)
          end
        end
      end
    end
  end
end
