module LocalBackups
  extend Syrus::PluginApi

  syrus_plugin "local_backups" do
    display_name "Local Backups"
    description "Discovers and inventories immutable local recovery bundles."
    long_description "Local Backups provides the portable manifest and inventory foundation for installation recovery. This first phase is read-only: it validates the configured backup root and rediscovers sealed bundles without creating, deleting, downloading, or restoring them."
    homepage "https://github.com/tkadauke/syrus"
    author "Thomas Kadauke"
    category "tooling"
    default_enabled false
    disableable true
    events "local_backups.backup.completed" => :async,
           "local_backups.backup.failed" => :async,
           "local_backups.backup.validated" => :async,
           "local_backups.backup.expiring" => :async,
           "local_backups.backup.deleted" => :async
    provides admin_page: "LocalBackups::AdminPages",
             backup_artifact_source: "LocalBackups::ArtifactSource"
    route :get, "/api/v1/app/admin/local_backups", to: "api/v1/app/admin/local_backups#index"
    route :get, "/admin/local_backups", to: "spa#show"
    frontend routes: { "local_backups/AdminLocalBackups" => "app/frontend/routes/AdminLocalBackups.tsx" },
        i18n: [ "app/frontend/i18n/locales/*/local_backups.json" ]
  end
end
