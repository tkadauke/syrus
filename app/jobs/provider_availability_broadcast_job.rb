class ProviderAvailabilityBroadcastJob < ApplicationJob
  queue_as :low_priority_maintenance

  def perform(user_id, provider, provider_account_id = nil)
    user = User.find_by(id: user_id)
    return unless user

    provider_account = user.provider_accounts.find_by(id: provider_account_id, provider_key: provider) if provider_account_id
    return if provider_account_id && provider_account.nil?

    App::ProviderAvailability.broadcast_changed(user: user, provider: provider, provider_account: provider_account)
  end
end
