require "digest"

module LocalBackups
  class EncryptionFingerprint
    def self.for(value)
      return if value.blank?

      "sha256:#{Digest::SHA256.hexdigest(value)}"
    end
  end
end
