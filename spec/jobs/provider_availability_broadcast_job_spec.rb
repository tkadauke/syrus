require "rails_helper"

RSpec.describe ProviderAvailabilityBroadcastJob do
  it "broadcasts delayed recovery for the user's pinned provider account" do
    user = Factories.user(claude_oauth_token: "first-token")
    account = user.default_provider_account("claude")
    allow(App::ProviderAvailability).to receive(:broadcast_changed)

    described_class.perform_now(user.id, "claude", account.id)

    expect(App::ProviderAvailability).to have_received(:broadcast_changed).with(
      user: user,
      provider: "claude",
      provider_account: account
    )
  end

  it "does not accept an account owned by another user" do
    user = Factories.user(claude_oauth_token: "first-token")
    other = Factories.user(claude_oauth_token: "other-token")
    allow(App::ProviderAvailability).to receive(:broadcast_changed)

    described_class.perform_now(user.id, "claude", other.default_provider_account("claude").id)

    expect(App::ProviderAvailability).not_to have_received(:broadcast_changed)
  end
end
