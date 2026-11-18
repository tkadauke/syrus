module ConnectedAccounts
  extend Syrus::PluginApi

  syrus_plugin "connected_accounts" do
    experimental true
    display_name "Connected Accounts"
    category "agent_capability"
    author "Thomas Kadauke"
    description "Brokered, permission-authorized access to user-owned external accounts."
    long_description "Connected Accounts stores safe external-account metadata and brokers short-lived access to credential-store-backed OAuth tokens without exposing long-lived credentials to tools."
    homepage "https://github.com/tkadauke/syrus"
    default_enabled false
    disableable true
    depends_on [ "credential_store" ]
    credential_types [
      {
        name: "connected_accounts.oauth",
        label: "Connected account OAuth tokens",
        description: "OAuth access and refresh tokens managed by Connected Accounts.",
        typed_consumer: {
          name: "connected_accounts.account_client",
          description: "Broker short-lived access for an authorized connected-account invocation."
        }
      }
    ]
  end
end
