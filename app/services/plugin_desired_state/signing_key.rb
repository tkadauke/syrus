require "openssl"

module PluginDesiredState
  class SigningKey
    PUBLIC_KEY_ENV = "SYRUS_PLUGIN_MANIFEST_PUBLIC_KEY"

    def self.generate!
      key = OpenSSL::PKey.generate_key("ED25519")
      AppSetting.current.update!(plugin_manifest_private_key_pem: key.private_to_pem)
      key.public_to_pem
    end

    def self.private_key
      pem = AppSetting.current.plugin_manifest_private_key_pem
      raise KeyMissing, "plugin manifest signing key is not configured" if pem.blank?

      OpenSSL::PKey.read(pem)
    end

    def self.public_key
      pem = ENV[PUBLIC_KEY_ENV].presence || private_key.public_to_pem
      OpenSSL::PKey.read(pem)
    end

    class KeyMissing < StandardError; end
  end
end
