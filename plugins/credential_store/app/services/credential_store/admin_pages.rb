module CredentialStore
  class AdminPages
    include Syrus::Plugin::AdminPage

    def self.admin_pages
      [
        {
          id: "credential_store.credentials",
          label: "Credential Store",
          label_key: "credential_store:nav_credentials",
          path: "/admin/credential_store",
          paths: [ "/admin/credential_store" ],
          component: "credential_store/CredentialStoreAdmin",
          group_id: "system",
          order: 85
        }
      ]
    end
  end
end
