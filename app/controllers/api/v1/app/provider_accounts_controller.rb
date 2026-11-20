module Api
  module V1
    module App
      class ProviderAccountsController < BaseController
        include ProviderAccountSerialization
        before_action :set_account, only: %i[update destroy test]

        def index
          render json: { provider_accounts: Current.user.provider_accounts.in_position_order.map { |account| provider_account_json(account) } }
        end

        def create
          provider = provider_class(params[:provider_key])
          return unless provider

          account = Current.user.provider_accounts.build(account_attributes(provider))
          account.position = (Current.user.provider_accounts.where(provider_key: provider.provider_key).maximum(:position) || -1) + 1
          account.provider_key = provider.provider_key
          account.authentication_kind = params[:authentication_kind].presence || inferred_authentication_kind(provider)
          account.credential_payload = credential_payload(provider)
          if account.save
            render json: { provider_account: provider_account_json(account), message: I18n.t("api.provider_accounts.created") }, status: :created
          else
            render_validation(account)
          end
        end

        def update
          attributes = params.permit(:label, :enabled, :weight, :proactive_pause_threshold, :authentication_kind).to_h
          attributes["label"] = attributes["label"].presence if attributes.key?("label")
          attributes["weight"] = attributes["weight"].presence if attributes.key?("weight")
          attributes["proactive_pause_threshold"] = attributes["proactive_pause_threshold"].presence if attributes.key?("proactive_pause_threshold")
          if params[:credentials].present?
            provider = AgentProviders.for(@account.provider_key)
            attributes["credential_payload"] = credential_payload(provider)
          end
          if @account.update(attributes)
            ::App::ProviderAvailability.broadcast_changed(user: Current.user, provider: @account.provider_key, provider_account: @account)
            render json: { provider_account: provider_account_json(@account), message: I18n.t("api.provider_accounts.updated") }
          else
            render_validation(@account)
          end
        end

        def destroy
          if @account.actively_referenced?
            return render_error("provider_account_in_use", I18n.t("api.provider_accounts.in_use"), status: :conflict)
          end

          @account.destroy!
          render json: { id: @account.public_id, message: I18n.t("api.provider_accounts.removed") }
        end

        def test
          result = AgentProviders.for(@account.provider_key).refresh_usage!(user: Current.user, provider_account: @account, force: true)
          availability = ::App::ProviderAvailability.for_user(Current.user, @account.provider_key, provider_account: @account, cached: false)
          render json: { provider_account: provider_account_json(@account, availability: availability), message: result.try(:message) || availability&.dig(:message) }
        rescue AgentProviders::ConfigurationError => error
          render_error("provider_account_test_failed", error.message, status: :unprocessable_content)
        end

        private

        def set_account
          @account = Current.user.provider_accounts.find_by!(public_id: params[:id])
        end

        def provider_class(key)
          provider = AgentProviders.for(key.to_s)
          return provider if provider.provider_key.in?(User.agent_providers)
        rescue AgentProviders::ConfigurationError
          render_error("unknown_provider", I18n.t("api.credentials.unknown_provider"), status: :unprocessable_content)
          nil
        end

        def account_attributes(provider)
          attributes = params.permit(:label, :enabled, :weight, :proactive_pause_threshold).to_h
          attributes["label"] = attributes["label"].presence if attributes.key?("label")
          attributes.merge(provider_key: provider.provider_key)
        end

        def credential_payload(provider)
          submitted = params.fetch(:credentials, ActionController::Parameters.new).permit(*provider.credential_attributes).to_h.stringify_keys
          provider.credential_attributes.index_with { |name| submitted[name.to_s] }.compact_blank
        end

        def inferred_authentication_kind(provider)
          payload = credential_payload(provider)
          payload["codex_auth_mode"].presence || provider.credential_attributes.find { |name| name.to_s != "codex_auth_mode" }.to_s
        end

        def render_validation(account)
          render_error("validation_failed", account.errors.full_messages.to_sentence, status: :unprocessable_content)
        end
      end
    end
  end
end
