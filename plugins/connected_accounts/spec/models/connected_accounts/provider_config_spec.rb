require "rails_helper"

RSpec.describe ConnectedAccounts::ProviderConfig do
  def build_config(**attributes)
    described_class.new({ provider_key: "generic_oauth2", authorize_url: "https://oauth.example/authorize",
      token_url: "https://oauth.example/token", identity_url: "https://api.example/me", client_id: "client",
      client_secret: "secret", scope_catalog: %w[profile email calendar.write], read_only_scopes: %w[profile email],
      api_origins: [ "https://api.example/" ] }.merge(attributes))
  end

  it "accepts an explicit read-only subset without inferring from scope names" do
    expect(build_config).to be_valid
  end

  it "rejects read-only scopes that are not offered by the provider" do
    config = build_config(read_only_scopes: %w[profile unknown])

    expect(config).not_to be_valid
    expect(config.errors[:read_only_scopes]).to include(I18n.t("connected_accounts.settings.read_only_scopes_not_in_catalog"))
  end
end
