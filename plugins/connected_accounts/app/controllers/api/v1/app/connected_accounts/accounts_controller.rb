module Api::V1::App::ConnectedAccounts
  class AccountsController < Api::V1::App::BaseController
    def index
      accounts = ::ConnectedAccounts::Account.where(owner_user: Current.user).includes(:credential_store_credential).order(:provider, :display_label)
      last_used = ::CredentialStore::CredentialAccessEvent.where(
        credential_id: accounts.map(&:credential_store_credential_id), action: "lease", result: "allowed"
      ).group(:credential_id).maximum(:created_at)
      providers = ::ConnectedAccounts::ProviderRegistry.all.filter_map do |provider|
        { key: provider.key, display_name: provider.display_name, scopes: provider.connect_scope_keys,
          supports_read_only: provider.supports_read_only }
      rescue ActiveRecord::RecordNotFound
        nil
      end
      render json: {
        accounts: accounts.map { |account| serialized(account, last_used[account.credential_store_credential_id]) },
        providers:
      }
    end

    def update
      account = owned_account
      read_only = ActiveModel::Type::Boolean.new.cast(params.require(:account).require(:read_only))
      ceiling = if read_only
        declaration = ::ConnectedAccounts::ProviderRegistry.fetch(account.provider)
        account.granted_scopes & declaration.read_only_scope_keys
      else
        account.granted_scopes
      end
      account.update!(read_only:, scope_ceiling: ceiling)
      render json: { account: serialized(account, account.last_used_at) }
    end

    def destroy
      account = owned_account
      ::ConnectedAccounts::Disconnector.call(account: account, user: Current.user)
      render json: { account: serialized(account, account.last_used_at) }
    end

    private

    def owned_account = ::ConnectedAccounts::Account.find_by!(id: params[:id], owner_user: Current.user)

    def serialized(account, last_used_at)
      {
        id: account.id, provider: account.provider, display_label: account.display_label,
        status: account.status, granted_scopes: account.granted_scopes, read_only: account.read_only,
        acting_modes: account.acting_modes, last_used_at: last_used_at&.iso8601,
        reauthorize_url: "/api/v1/app/connected_accounts/connect/#{CGI.escape(account.provider)}?#{URI.encode_www_form(
          scopes: account.granted_scopes.join(","), read_only: account.read_only
        )}"
      }
    end
  end
end
