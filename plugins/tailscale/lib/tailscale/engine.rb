module Tailscale
  class Engine < ::Rails::Engine
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name:            "tailscale",
        display_name:    "Tailscale",
        version:         Tailscale::VERSION,
        description:     "Exposes Syrus on your Tailscale network for access from laptops and mobile.",
        long_description: "Tailscale registers a Syrus instance as a Tailscale node so operators can reach it over a private tailnet. It manages lifecycle callbacks, status reporting, and the admin page needed to inspect connectivity.\n\nEnable it when an installation should be reachable without exposing Syrus directly on the public internet. It is disabled by default because it requires a Tailscale auth key and network policy decisions outside Syrus.",
        homepage:        "https://github.com/tkadauke/syrus",
        icon_url:        "/plugin-icons/tailscale.svg",
        author:          "Thomas Kadauke",
        default_enabled: false,
        disableable:     true,
        category:        "connectivity",
        home_queue:      :connectivity,
        tick_interval:   30.seconds,
        config_schema: [
          { key: "auth_key", label: "Auth Key", type: :secret_env, env_var: "TS_AUTHKEY",
            required: true, description: "Auth key for headless device registration. Set in .env." },
          { key: "hostname", label: "Device Hostname", type: :string, required: false,
            description: "Override the device name on the tailnet." },
          { key: "exit_node", label: "Advertise as exit node", type: :boolean,
            required: false, default: false }
        ],
        frontend: {
          routes: {
            "tailscale/AdminTailscale" => "app/frontend/routes/AdminTailscale.tsx"
          },
          i18n: [ "app/frontend/i18n/locales/*/tailscale.json" ]
        },
        routes: [
          {
            verb: "GET",
            path: "/api/v1/app/admin/tailscale/status",
            controller: "api/v1/app/admin/tailscale#status"
          },
          {
            verb: "GET",
            path: "/api/v1/admin/tailscale/status",
            controller: "api/v1/admin/tailscale#status"
          },
          {
            verb: "GET",
            path: "/admin/tailscale",
            controller: "spa#show"
          }
        ],
        provides: { callbacks: Tailscale::Callbacks, admin_page: Tailscale::AdminPages }
      )
    end
  end
end
