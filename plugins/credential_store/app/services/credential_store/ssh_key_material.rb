require "json"

module CredentialStore
  class SshKeyMaterial
    attr_reader :private_key, :passphrase

    def self.from_payload(payload)
      new(payload)
    end

    def initialize(payload)
      material = parse(payload)
      @private_key = normalize_private_key(material.fetch(:private_key))
      @passphrase = material[:passphrase]
    end

    def secrets
      [ private_key, passphrase ].compact
    end

    private

    def normalize_private_key(private_key)
      validate_private_key!(private_key)
      "#{private_key.sub(/(?:\r\n|\n)+\z/, "")}\n"
    end

    def validate_private_key!(private_key)
      stripped = private_key.lstrip
      if stripped.match?(/\A(?:ssh-|ecdsa-)/) || stripped.include?(" PUBLIC KEY-----")
        raise SshExec::InvalidTarget, "SSH credential payload must contain a private key, not a public key"
      end

      return unless stripped.start_with?("-----BEGIN ")
      return if stripped.match?(/\A-----BEGIN (?:OPENSSH |RSA |EC |DSA |ENCRYPTED )?PRIVATE KEY-----/) &&
        stripped.match?(/-----END (?:OPENSSH |RSA |EC |DSA |ENCRYPTED )?PRIVATE KEY-----(?:\r?\n)*\z/)

      raise SshExec::InvalidTarget, "SSH credential payload contains a malformed private key"
    end

    def parse(payload)
      parsed = JSON.parse(payload)
      unless parsed.is_a?(Hash) && parsed["private_key"].is_a?(String)
        raise SshExec::InvalidTarget, "private_key is required in SSH credential payload"
      end

      private_key = parsed.fetch("private_key")
      passphrase = parsed["passphrase"].to_s.presence
      raise SshExec::InvalidTarget, "private_key is required in SSH credential payload" if private_key.blank?

      { private_key: private_key, passphrase: passphrase }
    rescue JSON::ParserError
      private_key = payload.to_s
      raise SshExec::InvalidTarget, "private_key is required in SSH credential payload" if private_key.blank?

      { private_key: private_key, passphrase: nil }
    end
  end
end
