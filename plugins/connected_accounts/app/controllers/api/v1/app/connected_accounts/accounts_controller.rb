module Api::V1::App::ConnectedAccounts
  class AccountsController < Api::V1::App::BaseController
    def destroy
      account = ::ConnectedAccounts::Account.find_by!(id: params[:id], owner_user: Current.user)
      ::ConnectedAccounts::Disconnector.call(account: account, user: Current.user)
      render json: { account: { id: account.id, status: account.status } }
    end
  end
end
