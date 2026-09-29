class AgentSidecarEnvironment
  SECRET_ENV_KEYS = %w[
    RAILS_MASTER_KEY
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
    ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
    SECRET_KEY_BASE
    DATABASE_URL
    SYRUS_DATABASE_PASSWORD
    S3_ACCESS_KEY_ID
    S3_SECRET_ACCESS_KEY
    RETENTION_ARCHIVE_S3_ACCESS_KEY_ID
    RETENTION_ARCHIVE_S3_SECRET_ACCESS_KEY
  ].freeze

  SAFE_ENV_FORWARD = %w[
    RAILS_ENV
    RAILS_LOG_LEVEL
    RAILS_LOG_TO_STDOUT
    DB_HOST
    SYRUS_SQLITE
    SYRUS_DATA_ROOT
    BUNDLE_PATH
    BUNDLE_DEPLOYMENT
    BUNDLE_WITHOUT
    PATH
    TZ
    SYRUS_APP_HOST
    SYRUS_ALLOWED_HOSTS
    SYRUS_ASSUME_SSL
    SYRUS_FORCE_SSL
    S3_BUCKET
    S3_ENDPOINT
    S3_REGION
    RETENTION_ARCHIVE_S3_BUCKET
    RETENTION_ARCHIVE_S3_ENDPOINT
    RETENTION_ARCHIVE_S3_REGION
  ].freeze
  BOOT_ENV_FORWARD = (SAFE_ENV_FORWARD + SECRET_ENV_KEYS).freeze

  class << self
    def build(extra: {}, env: ENV)
      forwarded = env.slice(*SAFE_ENV_FORWARD).compact
      forwarded["SYRUS_DATA_ROOT"] ||= WorkflowWorkspace.data_root.to_s
      pin_rubygems_to_bundle_path(forwarded)
      filter(forwarded.merge(extra.compact))
    end

    def build_boot(extra: {}, env: ENV)
      forwarded = env.slice(*BOOT_ENV_FORWARD).compact
      forwarded["SYRUS_DATA_ROOT"] ||= WorkflowWorkspace.data_root.to_s
      pin_rubygems_to_bundle_path(forwarded)
      forwarded.merge(extra.compact)
    end

    def filter(env)
      env.to_h.compact.except(*SECRET_ENV_KEYS)
    end

    def filter_for_agent_config(server)
      server = server.to_h
      env = server[:env] || server["env"] || {}
      command = server[:command] || server["command"]
      direct_sidecar_command?(command) ? env.to_h.compact : filter(env)
    end

    def unsafe_key?(key)
      SECRET_ENV_KEYS.include?(key.to_s)
    end

    private

    def direct_sidecar_command?(command)
      File.basename(command.to_s) == "syrus-mcp-sidecar"
    end

    def pin_rubygems_to_bundle_path(forwarded)
      bundle_path = forwarded["BUNDLE_PATH"].presence
      return unless bundle_path

      forwarded["GEM_HOME"] ||= bundle_path
      forwarded["GEM_PATH"] ||= bundle_path
    end
  end
end
