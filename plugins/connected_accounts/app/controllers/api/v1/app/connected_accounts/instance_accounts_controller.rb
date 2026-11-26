module Api::V1::App::ConnectedAccounts
  class InstanceAccountsController < Syrus::Host::AppAdminController
    def index
      declarations = ::ConnectedAccounts::ProviderRegistry.all.select(&:token_authorization?)
      render json: {
        accounts: ::ConnectedAccounts::Account.where(owner_kind: "instance").order(:provider).map { |account| serialized(account) },
        providers: declarations.map { |item| { key: item.key, display_name: item.display_name } }
      }
    end

    def create
      account = ::ConnectedAccounts::TokenBroker.connect!(provider: account_params.fetch(:provider),
        token: account_params.fetch(:token), label: account_params[:display_label], admin: Syrus::Host::Current.user)
      render json: { account: serialized(account) }, status: :created
    rescue ::ConnectedAccounts::TokenBroker::Error => error
      render_error("validation_failed", error.message, status: :unprocessable_content)
    end

    def destroy
      account = ::ConnectedAccounts::Account.find_by!(id: params[:id], owner_kind: "instance")
      ::ConnectedAccounts::Disconnector.call(account:, user: Syrus::Host::Current.user)
      render json: { account: serialized(account) }
    end

    private

    def account_params = params.require(:account).permit(:provider, :token, :display_label)

    def serialized(account)
      { id: account.id, provider: account.provider, display_label: account.display_label,
        status: account.status, last_used_at: account.last_used_at&.iso8601 }
    end
  end
end
