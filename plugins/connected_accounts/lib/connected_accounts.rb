module ConnectedAccounts
  extend Syrus::PluginApi

  syrus_plugin "connected_accounts" do
    experimental true
    display_name "Connected accounts"
    display_name_i18n_key "connected_accounts:plugin.display_name"
    category     "tooling"
    author       "Thomas Kadauke"
    icon_url     "/plugin-icons/connected_accounts.svg"
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
        callback_route: "/api/v1/app/connected_accounts/callback/fake",
        supports_read_only: true,
        scopes: [
          {
            key: "fake.read",
            label: "Read fake records",
            risk: "low",
            read_only: true,
            syrus_capabilities: [ "records.read@v1" ]
          },
          {
            key: "fake.write",
            label: "Change fake records",
            risk: "high",
            read_only: false,
            syrus_capabilities: [ "records.write@v1" ]
          }
        ]
      },
      {
        provider: "ConnectedAccounts::GenericOauth2Provider", key: "generic_oauth2", display_name: "Generic OAuth 2",
        capabilities: %w[authorization exchange_code refresh revoke identity validate],
        callback_route: "/api/v1/app/connected_accounts/callback/generic_oauth2", supports_read_only: true,
        scopes: [
          { key: "read", label: "Read account data", risk: "low", read_only: true, syrus_capabilities: [ "account.read@v1" ] },
          { key: "write", label: "Change account data", risk: "high", read_only: false, syrus_capabilities: [ "account.write@v1" ] }
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
    provides admin_page: "ConnectedAccounts::AdminPages",
             sidebar_page: "ConnectedAccounts::SidebarPages",
             retention_policy: "ConnectedAccounts::RetentionPolicy"
    toolkit permissions: "ConnectedAccounts::PermissionProvider"
    route :get, "/api/v1/app/connected_accounts/accounts", to: "api/v1/app/connected_accounts/accounts#index"
    route :patch, "/api/v1/app/connected_accounts/accounts/:id", to: "api/v1/app/connected_accounts/accounts#update"
    route :get, "/api/v1/app/connected_accounts/connect/:provider", to: "api/v1/app/connected_accounts/oauth#start"
    route :get, "/api/v1/app/connected_accounts/callback/:provider", to: "api/v1/app/connected_accounts/oauth#callback"
    route :delete, "/api/v1/app/connected_accounts/accounts/:id", to: "api/v1/app/connected_accounts/accounts#destroy"
    route :get, "/api/v1/app/admin/connected_accounts/provider_config", to: "api/v1/app/connected_accounts/provider_configs#show"
    route :patch, "/api/v1/app/admin/connected_accounts/provider_config", to: "api/v1/app/connected_accounts/provider_configs#update"
    route :get, "/admin/connected_accounts", to: "spa#show"
    route :get, "/settings/connected_accounts", to: "spa#show"
    frontend routes: {
      "connected_accounts/ConnectedAccountsAdmin" => "app/frontend/routes/ConnectedAccountsAdmin.tsx",
      "connected_accounts/ConnectedAccountsSettings" => "app/frontend/routes/ConnectedAccountsSettings.tsx"
    },
      i18n: [ "app/frontend/i18n/locales/*/connected_accounts.json" ]
  end
end
