require "active_support/core_ext/object/blank"

# Resolves which Active Storage service backs RetentionArchive attachments.
# Independent of the app's primary attachment service (config.active_storage.service)
# so an operator can archive pruned rows to a dedicated large disk or bucket
# regardless of where regular attachments live. RETENTION_ARCHIVE_STORAGE_SERVICE
# overrides; unset falls back to the primary service so zero-config
# deployments are unaffected.
module RetentionArchiveStorageConfig
  ENV_KEY = "RETENTION_ARCHIVE_STORAGE_SERVICE"

  def self.resolve(config, env: ENV)
    override = env[ENV_KEY].presence
    (override || config.active_storage.service).to_sym
  end
end
