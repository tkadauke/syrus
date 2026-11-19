require "syrus/plugin/backup_destination"

module RelocatablePlugin
  extend Syrus::PluginApi

  syrus_plugin "relocatable_plugin" do
    provides callbacks: "RelocatablePlugin::Callbacks",
             backup_destination: "RelocatablePlugin::BackupDestination"

    cli_commands [
      {
        path: %w[relocation ping],
        summary: "Prove that an external plugin command executes",
        handler: "RelocatablePlugin::Cli::Ping"
      }
    ]

    route :get, "/api/v1/app/relocatable_plugin/ping", to: "api/v1/app/relocatable_plugin/ping#show"
    frontend bundle: "dist/frontend/plugin.js", css: "dist/frontend/plugin.css"
  end

  class Callbacks
  end

  class BackupDestination
    include Syrus::Plugin::BackupDestination

    def self.destination_key = "relocatable"
  end
end
