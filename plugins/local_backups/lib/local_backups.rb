module LocalBackups
  extend Syrus::PluginApi

  syrus_plugin "local_backups" do
    display_name "Local Backups"
    description "Creates and inventories sealed, portable recovery bundles on installation-local storage."
    long_description "Local Backups creates consistent SQLite or MySQL recovery bundles with streamed Active Storage objects, provides scheduled retention and validation, and offers audited downloads from an inventory reconstructed from sealed artifacts. Restore is delivered separately."
    homepage "https://github.com/tkadauke/syrus"
    author "Thomas Kadauke"
    category "tooling"
    icon_url "/plugin-icons/local_backups.svg"
    default_enabled false
    disableable true
    provides admin_pages: "LocalBackups::AdminPages", callbacks: "LocalBackups::Callbacks",
             system_alert_provider: "LocalBackups::Alerts",
             backup_artifact_source: "LocalBackups::ArtifactSource"
    tick_interval 1.day
    events "local_backups.backup.completed" => :async,
           "local_backups.backup.failed" => :async,
           "local_backups.backup.validated" => :async,
           "local_backups.backup.expiring" => :async,
           "local_backups.backup.deleted" => :async
    metrics do
      gauge(:completed_total, comment: "Completed local recovery bundles currently retained") { LocalBackups::Backup.where(state: "completed").count }
      gauge(:invalid_total, comment: "Retained local recovery bundles whose latest validation failed") { LocalBackups::Backup.where(state: "completed", verification_state: "invalid").count }
      gauge(:stored_bytes, comment: "Bytes used by retained local recovery bundles") { LocalBackups::Backup.where(state: "completed").sum(:stored_bytes) }
    end
    always "Active Storage purge guard" do |_scope|
      ActiveStorage::Blob.prepend(LocalBackups::PurgeGuard) unless ActiveStorage::Blob < LocalBackups::PurgeGuard
      nil
    end
    route :get, "/api/v1/app/admin/local_backups", to: "api/v1/app/admin/local_backups#index"
    route :post, "/api/v1/app/admin/local_backups", to: "api/v1/app/admin/local_backups#create"
    route :post, "/api/v1/app/admin/local_backups/:id/validate", to: "api/v1/app/admin/local_backups#validate"
    route :post, "/api/v1/app/admin/local_backups/:id/pin", to: "api/v1/app/admin/local_backups#pin"
    route :delete, "/api/v1/app/admin/local_backups/:id/pin", to: "api/v1/app/admin/local_backups#unpin"
    route :delete, "/api/v1/app/admin/local_backups/:id", to: "api/v1/app/admin/local_backups#destroy"
    route :get, "/api/v1/app/admin/local_backups/:id/download", to: "api/v1/app/admin/local_backups#download"
    route :get, "/admin/local_backups", to: "spa#show"
    frontend routes: { "local_backups/AdminLocalBackups" => "app/frontend/routes/AdminLocalBackups.tsx" },
      i18n: [ "app/frontend/i18n/locales/*/local_backups.json" ]
  end
end
