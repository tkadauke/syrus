module Tailscale
  class AdminPages
    include Syrus::Host::AdminPage

    def self.admin_pages
      [
        {
          id: "tailscale.status",
          label: "Tailscale",
          label_key: "tailscale:nav_tailscale",
          path: "/admin/tailscale",
          paths: [ "/admin/tailscale" ],
          component: "tailscale/AdminTailscale",
          order: 60
        }
      ]
    end
  end
end
