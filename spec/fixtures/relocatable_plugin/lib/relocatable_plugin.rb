module RelocatablePlugin
  extend Syrus::PluginApi

  syrus_plugin "relocatable_plugin" do
    provides callbacks: "RelocatablePlugin::Callbacks"

    cli_commands [
      {
        path: %w[relocation ping],
        summary: "Prove that an external plugin command executes",
        handler: "RelocatablePlugin::Cli::Ping"
      }
    ]

    route :get, "/api/v1/app/relocatable_plugin/ping", to: "api/v1/app/relocatable_plugin/ping#show"
    frontend bundle: "dist/frontend/plugin.js", css: "dist/frontend/plugin.css",
      i18n: [ "app/frontend/i18n/locales/*/relocatable_plugin.json" ]
  end

  class Callbacks
  end
end
