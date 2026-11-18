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
  end
end
