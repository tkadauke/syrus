module LocalBackups
  extend Syrus::PluginApi

  syrus_plugin "local_backups" do
    display_name "Local Backups"
    description "Discovers and inventories sealed, portable recovery bundles stored on installation-local storage."
    long_description "Local Backups provides the immutable backup-manifest contract and a read-only inventory reconstructed from sealed artifacts. Backup creation, retention, download, and restore are intentionally delivered separately."
    homepage "https://github.com/tkadauke/syrus"
    author "Thomas Kadauke"
    category "tooling"
    default_enabled false
    disableable true
    provides admin_page: "LocalBackups::AdminPages",
             backup_artifact_source: "LocalBackups::ArtifactSource"
    events "local_backups.backup.completed" => :async,
           "local_backups.backup.failed" => :async,
           "local_backups.backup.validated" => :async,
           "local_backups.backup.expiring" => :async,
           "local_backups.backup.deleted" => :async
    route :get, "/api/v1/app/admin/local_backups", to: "api/v1/app/admin/local_backups#index"
    route :get, "/admin/local_backups", to: "spa#show"
    frontend routes: { "local_backups/AdminLocalBackups" => "app/frontend/routes/AdminLocalBackups.tsx" },
      i18n: [ "app/frontend/i18n/locales/*/local_backups.json" ]
  end
end
