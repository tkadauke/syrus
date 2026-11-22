require "json"
require "set"

module Syrus
  module PluginPackage
    class TrustStore
      LABELS = %w[official verified community].freeze
      Publisher = Data.define(:fingerprint, :label)

      attr_reader :revoked_keys, :revoked_releases

      def self.load(source)
        data = source.respond_to?(:read) ? JSON.parse(source.read) : JSON.parse(File.read(source))
        new(data)
      end

      def initialize(data)
        @publishers = Array(data.fetch("publishers", [])).to_h do |publisher|
          fingerprint = publisher.fetch("fingerprint").downcase
          label = publisher.fetch("label")
          raise ArgumentError, "invalid publisher trust label: #{label}" unless LABELS.include?(label)
          [ fingerprint, Publisher.new(fingerprint:, label:) ]
        end
        @revoked_keys = Array(data.fetch("revoked_keys", [])).map(&:downcase).to_set
        @revoked_releases = Array(data.fetch("revoked_releases", []))
      end

      def publisher(fingerprint) = @publishers[fingerprint.to_s.downcase]

      def revoked_release?(name:, version:, digest:)
        revoked_releases.any? do |release|
          release["name"] == name && release["version"] == version &&
            (release["digest"].nil? || release["digest"] == digest)
        end
      end
    end
  end
end
