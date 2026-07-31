class ProviderAvailabilityBroadcastJob < ApplicationJob
  queue_as :default

  def perform(user_id, provider)
    user = User.find_by(id: user_id)
    return unless user

    App::ProviderAvailability.broadcast_changed(user: user, provider: provider)
  end
end
