module CredentialStore
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      [
        {
          id: "credential_store.credentials",
          label: "Credential Store",
          label_key: "credential_store:nav_credentials",
          path: "/credential_store",
          paths: [ "/credential_store" ],
          component: "credential_store/CredentialStoreAdmin",
          icon: "lock",
          order: 88
        }
      ]
    end
  end
end
