module CredentialStore
  extend Syrus::PluginApi

  syrus_plugin "credential_store" do
    experimental true
    display_name "Credential Store"
    description "Encrypted, scoped credential records and credential access audit history."
    long_description "Credential Store is the bundled home for generic credential records that do not belong as one-off encrypted columns on User. It stores payloads as encrypted blobs, keeps only safe metadata in displayable JSON columns, and records credential access attempts without retaining payload material."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/credential_store.svg"
    author "Thomas Kadauke"
    category "agent_capability"
    default_enabled true
    disableable true

    credential_types [
      { name: "ssh_private_key", label: "SSH private key", description: "Private key material for SSH access, constrained by host, user, fingerprint, or known-host metadata." },
      { name: "token", label: "Token", description: "Opaque token material constrained by safe metadata and target policy." },
      { name: "json", label: "JSON credential", description: "Opaque JSON credential material constrained by safe metadata and target policy." },
      { name: "env", label: "Environment credential", description: "Environment-style secret material constrained by safe metadata and target policy." },
      { name: "file_blob", label: "File blob", description: "Opaque file payload material constrained by safe metadata and target policy." },
      { name: "credential_store.generic", label: "Generic secret", description: "Opaque credential material with safe display metadata." },
      { name: "credential_store.ssh_key", label: "SSH key", description: "SSH key material constrained by host, user, or fingerprint metadata." },
      { name: "credential_store.kubeconfig", label: "Kubeconfig", description: "Kubernetes configuration constrained by context or cluster metadata." },
      { name: "credential_store.url_token", label: "URL token", description: "Token material constrained to one or more URL prefixes." }
    ]
    provides admin_page: "CredentialStore::AdminPages",
             sidebar_page: "CredentialStore::SidebarPages",
             mcp_tool_set: "CredentialStore::WorkflowToolSet",
             chat_mcp_tool_set: "CredentialStore::ChatToolSet"
    route :get, "/api/v1/app/credential_store/credentials", to: "api/v1/app/credential_store/credentials#index"
    route :post, "/api/v1/app/credential_store/credentials", to: "api/v1/app/credential_store/credentials#create"
    route :get, "/api/v1/app/credential_store/credentials/:id", to: "api/v1/app/credential_store/credentials#show"
    route :patch, "/api/v1/app/credential_store/credentials/:id", to: "api/v1/app/credential_store/credentials#update"
    route :post, "/api/v1/app/credential_store/credentials/:id/rotate", to: "api/v1/app/credential_store/credentials#rotate"
    route :post, "/api/v1/app/credential_store/credentials/:id/revoke", to: "api/v1/app/credential_store/credentials#revoke"
    route :delete, "/api/v1/app/credential_store/credentials/:id", to: "api/v1/app/credential_store/credentials#revoke"
    route :post, "/api/v1/app/credential_store/leases", to: "api/v1/app/credential_store/leases#create"
    route :post, "/api/v1/app/credential_store/exec_material", to: "api/v1/app/credential_store/leases#exec_material"
    route :post, "/api/v1/app/credential_store/exec/audit", to: "api/v1/app/credential_store/leases#exec_audit"
    route :post, "/api/v1/app/credential_store/ssh_agent", to: "api/v1/app/credential_store/leases#ssh_agent"
    route :post, "/api/v1/app/credential_store/ssh_agent/audit", to: "api/v1/app/credential_store/leases#ssh_agent_audit"
    route :get, "/credential_store", to: "spa#show"
    route :get, "/admin/credential_store", to: "spa#show"
    frontend routes: {
          "credential_store/CredentialStoreAdmin" => "app/frontend/routes/CredentialStoreAdmin.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/credential_store.json" ]
  end
end
