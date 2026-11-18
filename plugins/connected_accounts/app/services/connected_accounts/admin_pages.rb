module ConnectedAccounts
  class AdminPages
    include Syrus::Plugin::AdminPage
    def self.admin_pages
      [ { id: "connected_accounts.providers", label: "OAuth providers",
          label_key: "connected_accounts:admin.nav", path: "/admin/connected_accounts",
          paths: [ "/admin/connected_accounts" ], component: "connected_accounts/AdminConnectedAccounts",
          group_id: "system", order: 86 } ]
    end
  end
end
