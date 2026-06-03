require "active_support/core_ext/object/blank"

module ActiveRecordEncryptionConfig
  ENV_KEYS = {
    primary_key: "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY",
    deterministic_key: "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY",
    key_derivation_salt: "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"
  }.freeze

  def self.apply_env_overrides!(config, env: ENV)
    values = ENV_KEYS.transform_values { |key| env[key].presence }
    return false if values.values.none?

    missing_keys = values.filter_map do |config_key, value|
      ENV_KEYS.fetch(config_key) if value.blank?
    end

    if missing_keys.any?
      raise KeyError, "Missing Active Record encryption environment variables: #{missing_keys.join(', ')}"
    end

    values.each do |config_key, value|
      config.active_record.encryption.public_send("#{config_key}=", value)
    end

    true
  end
end
