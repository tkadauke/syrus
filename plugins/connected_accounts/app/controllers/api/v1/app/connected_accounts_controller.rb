module Api
  module V1
    module App
      class ConnectedAccountsController < BaseController
        def index
          render json: { accounts: ::ConnectedAccounts::Account.where(owner_user: Current.user).order(:display_label).map { |account| serialize(account) } }
        end

        def authorize
          provider = params.require(:provider).to_s
          callback = "#{request.base_url}/api/v1/app/connected_accounts/callback/#{provider}"
          url = ::ConnectedAccounts::OauthFlow.start!(provider: provider, user: Current.user,
            redirect_uri: callback, scopes: Array(params.require(:scopes)), read_only: params[:read_only])
          redirect_to url, allow_other_host: true
        rescue KeyError, ArgumentError => error
          render_error("invalid_oauth_request", error.message, status: :unprocessable_content)
        end

        def callback
          account = ::ConnectedAccounts::OauthFlow.complete!(state: params.require(:state), code: params.require(:code), provider: params[:provider])
          redirect_to "/settings/connected_accounts?connected=#{account.id}"
        rescue ::ConnectedAccounts::OauthFlow::InvalidState
          redirect_to "/settings/connected_accounts?oauth_error=invalid_state"
        rescue StandardError => error
          Rails.logger.warn("Connected account OAuth callback failed: #{error.class.name}")
          redirect_to "/settings/connected_accounts?oauth_error=connection_failed"
        end

        def destroy
          account = ::ConnectedAccounts::Account.where(owner_user: Current.user).find(params[:id])
          ::ConnectedAccounts::Disconnector.call(account: account, user: Current.user)
          render json: { account: serialize(account) }
        rescue ::ConnectedAccounts::Problem => error
          response.set_header("Retry-After", error.retry_after.to_s) if error.retry_after
          render_error(error.code, error.message, status: :bad_gateway)
        end

        private

        def serialize(account)
          account.slice(:id, :provider, :display_label, :granted_scopes, :status, :read_only,
            :token_expires_at, :last_health_checked_at, :health_message)
        end
      end
    end
  end
end
