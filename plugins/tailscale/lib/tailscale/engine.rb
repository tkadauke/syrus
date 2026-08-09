module Tailscale
  class Engine < ::Rails::Engine
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name:            "tailscale",
        display_name:    "Tailscale",
        version:         Tailscale::VERSION,
        description:     "Exposes Syrus on your Tailscale network for access from laptops and mobile.",
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
        provides: { callbacks: Tailscale::Callbacks }
      )
    end
  end
end
