require "base64"
require "digest"
require "json"
require "openssl"

module Syrus
  module PluginPackage
    class TrustStore
      LABELS = %w[official verified community].freeze

      Verification = Data.define(:trusted, :label, :fingerprint, :reason) do
        def trusted? = trusted
        def revoked? = reason.to_s.start_with?("revoked_")
      end

      def self.fingerprint(public_key)
        "sha256:#{Digest::SHA256.hexdigest(public_key.public_to_der)}"
      end

      def self.load(path)
        new(JSON.parse(File.read(path)))
      end

      def initialize(document)
        @document = document.with_indifferent_access
        raise ArgumentError, "unsupported plugin trust store version" unless @document[:version] == 1

        @keys = Array(@document[:keys]).to_h do |item|
          item = item.with_indifferent_access
          label = item.fetch(:label)
          raise ArgumentError, "invalid plugin trust label: #{label}" unless LABELS.include?(label)

          key = OpenSSL::PKey.read(Base64.strict_decode64(item.fetch(:public_key)))
          fingerprint = self.class.fingerprint(key)
          raise ArgumentError, "publisher key fingerprint does not match public key" unless fingerprint == item.fetch(:fingerprint)
          [ fingerprint, { key:, label: } ]
        end
      end

      def verify(package:, signature:, name:, version:)
        envelope = signature.respond_to?(:read) ? JSON.parse(signature.read) : JSON.parse(File.read(signature))
        fingerprint = envelope.fetch("fingerprint")
        return result(false, nil, fingerprint, "revoked_key") if Array(@document[:revoked_keys]).include?(fingerprint)

        digest = Digest::SHA256.file(package).hexdigest
        revoked_release = Array(@document[:revoked_releases]).any? do |release|
          release = release.with_indifferent_access
          release[:name] == name && release[:version] == version && (!release[:digest] || release[:digest] == digest)
        end
        return result(false, nil, fingerprint, "revoked_release") if revoked_release

        publisher = @keys[fingerprint]
        return result(false, nil, fingerprint, "unknown_key") unless publisher
        return result(false, publisher[:label], fingerprint, "invalid_signature") unless envelope["algorithm"] == "ed25519" &&
          envelope["version"] == 1 && envelope["digest"] == "sha256:#{digest}" &&
          publisher[:key].verify(nil, Base64.strict_decode64(envelope.fetch("signature")), [ digest ].pack("H*"))

        result(true, publisher[:label], fingerprint, nil)
      rescue JSON::ParserError, KeyError, ArgumentError
        result(false, nil, nil, "invalid_signature")
      end

      # Local development installs have no publisher provenance. Keeping this
      # explicit prevents callers from confusing "allowed locally" with a
      # cryptographically verified package.
      def unsigned_local
        result(false, "unsigned_local", nil, "unsigned_local")
      end

      private

      def result(trusted, label, fingerprint, reason)
        Verification.new(trusted:, label:, fingerprint:, reason:)
      end
    end
  end
end
