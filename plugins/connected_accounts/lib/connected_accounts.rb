module ConnectedAccounts
  extend Syrus::PluginApi

  syrus_plugin "connected_accounts" do
    experimental true
    display_name "Connected Accounts"
    category "agent_capability"
    author "Thomas Kadauke"
    description "Brokered, permission-authorized access to user-owned external accounts."
    long_description "Connected Accounts owns external account metadata and provides the only supported path for tools to materialize short-lived OAuth access without exposing stored credentials."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/connected_accounts.svg"
    default_enabled false
    disableable true
    depends_on [ "credential_store" ]
    credential_types [
      {
        name: "connected_accounts.oauth",
        label: "Connected account OAuth tokens",
        description: "OAuth access and refresh token material managed exclusively by the Connected Accounts broker."
      }
    ]
  end
end
