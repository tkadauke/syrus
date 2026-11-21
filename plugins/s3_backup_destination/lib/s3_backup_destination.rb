module S3BackupDestination
  extend Syrus::PluginApi

  syrus_plugin "s3_backup_destination" do
    display_name "S3 Backup Destination"
    description "Replicates sealed local recovery bundles to S3-compatible object storage."
    long_description "S3 Backup Destination streams immutable recovery bundles through the public artifact-source capability, verifies uploaded bytes remotely, and can materialize verified objects into host-provided recovery storage."
    homepage "https://github.com/tkadauke/syrus"
    author "Thomas Kadauke"
    category "tooling"
    version "0.1.0"
    default_enabled false
    disableable true
    config_schema [
      { key: "bucket", label: "Backup bucket", type: :secret_env, env_var: "SYRUS_BACKUP_S3_BUCKET", required: true,
        description: "S3-compatible bucket used only for encrypted recovery bundles." },
      { key: "endpoint", label: "S3 endpoint", type: :secret_env, env_var: "SYRUS_BACKUP_S3_ENDPOINT", required: false,
        description: "Optional S3-compatible endpoint." },
      { key: "access_key_id", label: "Access key", type: :secret_env, env_var: "SYRUS_BACKUP_S3_ACCESS_KEY_ID", required: true,
        description: "Credential isolated to the backup destination bucket." },
      { key: "secret_access_key", label: "Secret key", type: :secret_env, env_var: "SYRUS_BACKUP_S3_SECRET_ACCESS_KEY", required: true,
        description: "Credential isolated to the backup destination bucket." }
    ]
    provides backup_destination: "S3BackupDestination::Destination",
             domain_subscriber: "S3BackupDestination::Subscriber"
  end
end
