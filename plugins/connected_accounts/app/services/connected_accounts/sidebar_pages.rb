module ConnectedAccounts
  class SidebarPages
    include Syrus::Host::SidebarPage

    def self.sidebar_pages
      [
        {
          id: "connected_accounts.accounts",
          label: "Connected accounts",
          label_key: "connected_accounts:nav_accounts",
          path: "/settings/connected_accounts",
          paths: [ "/settings/connected_accounts" ],
          component: "connected_accounts/ConnectedAccountsSettings",
          section: "settings",
          order: 75
        }
      ]
    end
  end
end
