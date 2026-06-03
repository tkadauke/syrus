require "rails_helper"
require Rails.root.join("config/active_record_encryption")

RSpec.describe ActiveRecordEncryptionConfig do
  EncryptionConfig = Struct.new(:primary_key, :deterministic_key, :key_derivation_salt, keyword_init: true)
  ActiveRecordConfig = Struct.new(:encryption, keyword_init: true)
  AppConfig = Struct.new(:active_record, keyword_init: true)

  def app_config
    AppConfig.new(active_record: ActiveRecordConfig.new(encryption: EncryptionConfig.new))
  end

  it "leaves Rails credentials fallback untouched when env keys are absent" do
    config = app_config

    applied = described_class.apply_env_overrides!(config, env: {})

    expect(applied).to be false
    expect(config.active_record.encryption.primary_key).to be_nil
    expect(config.active_record.encryption.deterministic_key).to be_nil
    expect(config.active_record.encryption.key_derivation_salt).to be_nil
  end

  it "sets Active Record encryption keys from env" do
    config = app_config

    applied = described_class.apply_env_overrides!(
      config,
      env: {
        "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "primary",
        "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "deterministic",
        "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "salt"
      }
    )

    expect(applied).to be true
    expect(config.active_record.encryption.primary_key).to eq("primary")
    expect(config.active_record.encryption.deterministic_key).to eq("deterministic")
    expect(config.active_record.encryption.key_derivation_salt).to eq("salt")
  end

  it "fails fast when only some env keys are configured" do
    expect {
      described_class.apply_env_overrides!(
        app_config,
        env: {
          "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "primary"
        }
      )
    }.to raise_error(
      KeyError,
      "Missing Active Record encryption environment variables: ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY, ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"
    )
  end
end
