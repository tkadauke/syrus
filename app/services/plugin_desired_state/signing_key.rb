require "base64"
require "ed25519"

class PluginDesiredState::SigningKey
  class PublicKeyMismatch < StandardError; end

  def self.generate!
    signing_key = Ed25519::SigningKey.generate
    AppSetting.current.update!(plugin_manifest_signing_key: Base64.strict_encode64(signing_key.to_bytes))
    new(signing_key).tap(&:validate_configured_public_key!)
  end

  def self.current
    encoded = AppSetting.current.plugin_manifest_signing_key
    return generate! if encoded.blank?

    new(Ed25519::SigningKey.new(Base64.strict_decode64(encoded))).tap(&:validate_configured_public_key!)
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
end
