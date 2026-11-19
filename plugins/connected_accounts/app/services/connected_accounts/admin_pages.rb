module ConnectedAccounts
  class AdminPages
    include Syrus::Plugin::AdminPage
    def self.admin_pages
      [ { id: "connected_accounts.settings", label: "Connected accounts", label_key: "connected_accounts:settings.title",
          path: "/admin/connected_accounts", paths: [ "/admin/connected_accounts" ], component: "connected_accounts/ConnectedAccountsAdmin",
          group_id: "system", order: 86 } ]
    end
  end
end
