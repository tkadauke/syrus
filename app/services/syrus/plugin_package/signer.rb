require "base64"
require "digest"
require "json"
require "openssl"
require_relative "trust_store"

module Syrus
  module PluginPackage
    class Signer
      def initialize(private_key)
        @private_key = OpenSSL::PKey.read(File.binread(private_key))
      end

      def sign(package)
        digest = Digest::SHA256.file(package).digest
        JSON.pretty_generate(
          "version" => 1,
          "algorithm" => "ed25519",
          "fingerprint" => TrustStore.fingerprint(@private_key),
          "digest" => "sha256:#{digest.unpack1("H*")}",
          "signature" => Base64.strict_encode64(@private_key.sign(nil, digest))
        ) + "\n"
      end
    end
  end
end
