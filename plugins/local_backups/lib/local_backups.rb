module LocalBackups
  extend Syrus::PluginApi

  syrus_plugin "local_backups" do
    display_name "Local Backups"
    description "Creates and inventories sealed, portable recovery bundles on installation-local storage."
    long_description "Local Backups creates consistent SQLite and Disk Active Storage recovery bundles, and provides an immutable backup-manifest contract with inventory reconstructed from sealed artifacts. Scheduling, retention, download, and restore are delivered separately."
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
    always "Active Storage purge guard" do |_scope|
      ActiveStorage::Blob.prepend(LocalBackups::PurgeGuard) unless ActiveStorage::Blob < LocalBackups::PurgeGuard
      nil
    end
    route :get, "/api/v1/app/admin/local_backups", to: "api/v1/app/admin/local_backups#index"
    route :get, "/admin/local_backups", to: "spa#show"
    frontend routes: { "local_backups/AdminLocalBackups" => "app/frontend/routes/AdminLocalBackups.tsx" },
      i18n: [ "app/frontend/i18n/locales/*/local_backups.json" ]
  end
end
