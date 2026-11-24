module RuntimeImages
  module Builds
    # Tunables for build admission and retries. Environment-overridable so
    # operators can size the plane without a deploy.
    module Config
      PLATFORMS = %w[linux/amd64 linux/arm64].freeze
      MAX_RECIPE_BYTES = 64.kilobytes

      def self.max_concurrent_builds = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_CONCURRENCY", 2))
      def self.max_concurrent_per_namespace = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_NAMESPACE_CONCURRENCY", 1))
      def self.max_attempts = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_MAX_ATTEMPTS", 3))
      def self.lease_duration = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_LEASE_SECONDS", 1800)).seconds

      # Exponential backoff before the next attempt: 30s, 60s, 120s, ...
      def self.retry_delay(attempts_made) = (30 * (2**[ attempts_made - 1, 0 ].max)).seconds
    end
  end
end
