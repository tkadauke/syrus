module CredentialStore
  extend Syrus::PluginApi

  syrus_plugin "credential_store" do
    display_name "Credential Store"
    description "Encrypted, scoped credential records and credential access audit history."
    long_description "Credential Store is the bundled home for generic credential records that do not belong as one-off encrypted columns on User. It stores payloads as encrypted blobs, keeps only safe metadata in displayable JSON columns, and records credential access attempts without retaining payload material."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/credential_store.svg"
    author "Thomas Kadauke"
    category "agent_capability"
    default_enabled true
    disableable true
  end
end
