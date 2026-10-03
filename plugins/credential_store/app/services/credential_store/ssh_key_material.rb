require "json"

module CredentialStore
  class SshKeyMaterial
    attr_reader :private_key, :passphrase

    def self.from_payload(payload)
      new(payload)
    end

    def initialize(payload)
      material = parse(payload)
      @private_key = material.fetch(:private_key)
      @passphrase = material[:passphrase]
    end

    def secrets
      [ private_key, passphrase ].compact
    end

    private

    def parse(payload)
      parsed = JSON.parse(payload)
      private_key = parsed.fetch("private_key").to_s
      passphrase = parsed["passphrase"].to_s.presence
      raise SshExec::InvalidTarget, "private_key is required in SSH credential payload" if private_key.blank?

      { private_key: private_key, passphrase: passphrase }
    rescue JSON::ParserError
      private_key = payload.to_s
      raise SshExec::InvalidTarget, "private_key is required in SSH credential payload" if private_key.blank?

      { private_key: private_key, passphrase: nil }
    rescue KeyError
      raise SshExec::InvalidTarget, "private_key is required in SSH credential payload"
    end
  end
end
