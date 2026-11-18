module ConnectedAccounts
  extend Syrus::PluginApi

  syrus_plugin "connected_accounts" do
    experimental true
    display_name "Connected accounts"
    display_name_i18n_key "connected_accounts:plugin.display_name"
    category     "tooling"
    author       "Thomas Kadauke"
    description  "Broker access to user-owned external accounts without exposing long-lived credentials."
    description_i18n_key "connected_accounts:plugin.description"
    long_description "Connected Accounts owns external account metadata and brokers short-lived, authorized access to OAuth credentials stored by Credential Store."
    long_description_i18n_key "connected_accounts:plugin.long_description"
    default_enabled false
    disableable true
    depends_on [ "credential_store" ]
    hosts :provider
    provides "connected_accounts:provider" => [
      {
        provider: "ConnectedAccounts::FakeProvider",
        key: "fake",
        display_name: "Fake service",
        capabilities: %w[authorization exchange_code refresh revoke identity validate events],
        callback_route: "/connected_accounts/callback/fake",
        supports_read_only: true,
        scopes: [
          {
            key: "fake.read",
            label: "Read fake records",
            risk: "low",
            syrus_capabilities: [ "records.read@v1" ]
          },
          {
            key: "fake.write",
            label: "Change fake records",
            risk: "high",
            syrus_capabilities: [ "records.write@v1" ]
          }
        ]
      }
    ]
    credential_types [
      {
        name: "connected_accounts.oauth",
        label: "Connected account OAuth tokens",
        description: "OAuth access and refresh token payload for a connected external account.",
        typed_consumer: {
          name: "connected_accounts.broker",
          description: "Brokered in-memory access to connected account tokens."
        }
      }
    ]
    while_enabled("provider contract") do
      ConnectedAccounts::ProviderRegistry.load!
      nil
    end
  end
end
