require "base64"
require "digest"
require "ed25519"
require "json"

module Syrus
  module PluginPackage
    class Verifier
      Result = Data.define(:valid, :trust_label, :fingerprint, :errors) do
        def valid? = valid
      end

      def initialize(package:, signature:, trust_store:, local: false, name: nil, version: nil)
        @package = package
        @signature = signature
        @trust_store = trust_store
        @local = local
        @name = name
        @version = version
      end

      def call
        return unsigned_result if @signature.nil?

        envelope = @signature.respond_to?(:read) ? JSON.parse(@signature.read) : JSON.parse(File.read(@signature))
        digest = digest_for(@package)
        return failure("signature digest does not match package") unless envelope["digest"] == digest
        if @name && @version && @trust_store.revoked_release?(name: @name, version: @version, digest:)
          return failure("plugin release has been revoked")
        end
        return failure("unsupported signature algorithm") unless envelope["algorithm"] == "ed25519"

        public_key = Base64.strict_decode64(envelope.fetch("public_key"))
        fingerprint = Digest::SHA256.hexdigest(public_key)
        return failure("signature fingerprint does not match public key", fingerprint:) unless envelope["fingerprint"] == fingerprint
        return failure("publisher key has been revoked", fingerprint:) if @trust_store.revoked_keys.include?(fingerprint)

        Ed25519::VerifyKey.new(public_key).verify(Base64.strict_decode64(envelope.fetch("signature")), digest)
        publisher = @trust_store.publisher(fingerprint)
        return failure("publisher key is not present in the trust store", fingerprint:) unless publisher
        unless owns_name?(publisher)
          return failure("publisher does not own plugin name prefix: #{@name}", fingerprint:)
        end

        Result.new(valid: true, trust_label: publisher.label, fingerprint:, errors: [])
      rescue Ed25519::VerifyError
        failure("signature verification failed", fingerprint: defined?(fingerprint) ? fingerprint : nil)
      rescue JSON::ParserError, KeyError, ArgumentError => error
        failure("invalid detached signature: #{error.message}")
      end

      private

      # The signer, not the publisher an index entry declares, must own the
      # name prefix. A registry signer must declare one, as the listing
      # requires; a local upload is held to its signer's prefix if it has one.
      def owns_name?(publisher)
        return true unless @name
        return publisher.prefix.nil? || publisher.prefix == TrustStore.name_prefix(@name) if @local

        publisher.prefix.present? && publisher.prefix == TrustStore.name_prefix(@name)
      end

      def unsigned_result
        return Result.new(valid: true, trust_label: "unsigned_local", fingerprint: nil, errors: []) if @local
        failure("unsigned packages are allowed only for local installation")
      end

      def digest_for(source)
        io = source.respond_to?(:read) ? source : File.open(source, "rb")
        Digest::SHA256.hexdigest(io.read)
      ensure
        io.rewind if source.respond_to?(:rewind)
        io.close if io && !source.respond_to?(:read)
      end

      def failure(message, fingerprint: nil)
        Result.new(valid: false, trust_label: nil, fingerprint:, errors: [ message ])
      end
    end
  end
end
