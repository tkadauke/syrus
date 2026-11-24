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

      # Per-build ceilings enforced by the isolated builder.
      def self.build_cpus = Float(ENV.fetch("RUNTIME_IMAGE_BUILD_CPUS", 2))
      def self.build_memory_bytes = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_MEMORY_BYTES", 4.gigabytes))
      def self.build_pids = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_PIDS", 512))
      def self.build_storage_bytes = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_STORAGE_BYTES", 10.gigabytes))
      def self.build_duration = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_TIMEOUT_SECONDS", 1500))
      def self.build_log_bytes = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_LOG_BYTES", 5.megabytes))
      def self.max_output_bytes = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_MAX_OUTPUT_BYTES", 2.gigabytes))
      def self.cache_max_bytes = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_CACHE_MAX_BYTES", 20.gigabytes))
      def self.max_source_bytes = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_MAX_SOURCE_BYTES", 1.gigabyte))
      def self.max_source_entries = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_MAX_SOURCE_ENTRIES", 200_000))
      def self.build_binary = ENV.fetch("RUNTIME_IMAGE_BUILD_BINARY", "buildah")
      def self.storage_driver = ENV.fetch("RUNTIME_IMAGE_BUILD_STORAGE_DRIVER", "vfs")

      # Exponential backoff before the next attempt: 30s, 60s, 120s, ...
      def self.retry_delay(attempts_made) = (30 * (2**[ attempts_made - 1, 0 ].max)).seconds
    end
  end
end
