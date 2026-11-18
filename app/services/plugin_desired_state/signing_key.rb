require "base64"
require "ed25519"

class PluginDesiredState::SigningKey
  class KeyAlreadyExists < StandardError; end
  class PublicKeyMismatch < StandardError; end

  def self.generate!
    setting = AppSetting.current
    setting.with_lock do
      raise KeyAlreadyExists, "plugin manifest signing key already exists" if setting.plugin_manifest_signing_key.present?

      key, encoded = build_generated_key
      setting.update!(plugin_manifest_signing_key: encoded)
      key
    end
  end

  def self.current
    setting = AppSetting.current
    setting.with_lock do
      encoded = setting.plugin_manifest_signing_key
      return from_encoded(encoded) if encoded.present?

      key, encoded = build_generated_key
      setting.update!(plugin_manifest_signing_key: encoded)
      key
    end
  end

  def initialize(signing_key)
    @signing_key = signing_key
  end

  def sign(message)
    @signing_key.sign(message)
  end

  def public_key
    Base64.strict_encode64(@signing_key.verify_key.to_bytes)
  end

  def validate_configured_public_key!
    configured = ENV["SYRUS_PLUGIN_MANIFEST_PUBLIC_KEY"].presence
    if configured && !ActiveSupport::SecurityUtils.secure_compare(configured, public_key)
      raise PublicKeyMismatch, "SYRUS_PLUGIN_MANIFEST_PUBLIC_KEY does not match the control-plane signing key"
    end
    self
  end

  class << self
    private

    def build_generated_key
      signing_key = Ed25519::SigningKey.generate
      key = new(signing_key).tap(&:validate_configured_public_key!)
      [ key, Base64.strict_encode64(signing_key.to_bytes) ]
    end

    def from_encoded(encoded)
      new(Ed25519::SigningKey.new(Base64.strict_decode64(encoded))).tap(&:validate_configured_public_key!)
    end
  end
end
