require "connected_accounts/data_cleanup"

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
    home_queue :low_priority_maintenance
    tick_interval 1.minute
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
      },
      {
        name: "connected_accounts.oauth_client",
        label: "Connected account OAuth client",
        description: "Instance OAuth client id and secret for a configured provider."
      }
    ]
    provides admin_page: "ConnectedAccounts::AdminPages", callbacks: "ConnectedAccounts::Callbacks"
    route :get, "/api/v1/app/connected_accounts", to: "api/v1/app/connected_accounts#index"
    route :get, "/api/v1/app/connected_accounts/authorize/:provider", to: "api/v1/app/connected_accounts#authorize"
    route :get, "/api/v1/app/connected_accounts/callback/:provider", to: "api/v1/app/connected_accounts#callback"
    route :delete, "/api/v1/app/connected_accounts/:id", to: "api/v1/app/connected_accounts#destroy"
    route :get, "/api/v1/app/admin/connected_account_providers", to: "api/v1/app/admin/connected_account_providers#index"
    route :post, "/api/v1/app/admin/connected_account_providers", to: "api/v1/app/admin/connected_account_providers#create"
    route :delete, "/api/v1/app/admin/connected_account_providers/:id", to: "api/v1/app/admin/connected_account_providers#destroy"
    frontend routes: { "connected_accounts/AdminConnectedAccounts" => "app/frontend/routes/AdminConnectedAccounts.tsx" },
      i18n: [ "app/frontend/i18n/locales/*/connected_accounts.json" ]
    while_enabled("provider contract") do
      ConnectedAccounts::ProviderRegistry.load!
      ConnectedAccounts::AccountClient.refresh_handler = ConnectedAccounts::TokenManager.method(:refresh)
      nil
    end
    always { |scope| ConnectedAccounts::DataCleanup.install_into(scope) }
  end
end
