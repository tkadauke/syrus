module RuntimeImages
  module Builds
    # Tunables for build admission and retries. Environment-overridable so
    # operators can size the plane without a deploy.
    module Config
      PLATFORMS = %w[linux/amd64 linux/arm64].freeze
      MAX_RECIPE_BYTES = 64.kilobytes

      def self.admin(key, env_key, fallback) = EnvironmentPolicy.current.override("builder", key) || ENV.fetch(env_key, fallback)
      def self.max_concurrent_builds = Integer(admin("max_concurrent_builds", "RUNTIME_IMAGE_BUILD_CONCURRENCY", 2))
      def self.max_concurrent_per_namespace = Integer(admin("max_concurrent_per_namespace", "RUNTIME_IMAGE_BUILD_NAMESPACE_CONCURRENCY", 1))
      def self.max_attempts = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_MAX_ATTEMPTS", 3))
      def self.lease_duration = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_LEASE_SECONDS", 1800)).seconds

      # Per-build ceilings enforced by the isolated builder.
      def self.build_cpus = Float(admin("cpus", "RUNTIME_IMAGE_BUILD_CPUS", 2))
      def self.build_memory_bytes = Integer(admin("memory_bytes", "RUNTIME_IMAGE_BUILD_MEMORY_BYTES", 4.gigabytes))
      def self.build_pids = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_PIDS", 512))
      def self.build_storage_bytes = Integer(admin("storage_bytes", "RUNTIME_IMAGE_BUILD_STORAGE_BYTES", 10.gigabytes))
      def self.build_duration = Integer(admin("timeout_seconds", "RUNTIME_IMAGE_BUILD_TIMEOUT_SECONDS", 1500))
      def self.build_log_bytes = Integer(admin("log_bytes", "RUNTIME_IMAGE_BUILD_LOG_BYTES", 5.megabytes))
      def self.max_output_bytes = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_MAX_OUTPUT_BYTES", 2.gigabytes))
      def self.max_source_bytes = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_MAX_SOURCE_BYTES", 1.gigabyte))
      def self.max_source_entries = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_MAX_SOURCE_ENTRIES", 200_000))
      def self.worker_confined? = ENV["RUNTIME_IMAGE_BUILD_WORKER_CONFINED"] == "1"
      def self.cgroup_optional? = ENV["RUNTIME_IMAGE_BUILD_CGROUP_OPTIONAL"] == "1"
      def self.build_binary = ENV.fetch("RUNTIME_IMAGE_BUILD_BINARY", "buildah")
      def self.storage_driver = ENV.fetch("RUNTIME_IMAGE_BUILD_STORAGE_DRIVER", "vfs")

      # Hard ceiling on one attempt's wall clock, heartbeats or not: the build
      # timeout plus time to publish and verify. Past it the attempt is stale.
      def self.max_attempt_runtime = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_MAX_ATTEMPT_SECONDS", build_duration + 900)).seconds
      # A queued request older than this with free capacity is reported as stuck.
      def self.stuck_queue_after = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_STUCK_QUEUE_SECONDS", 900)).seconds
      # An attempt whose lease lapsed this long ago means the reaper is not running.
      def self.stale_lease_grace = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_STALE_LEASE_GRACE_SECONDS", 300)).seconds

      # Exponential backoff before the next attempt: 30s, 60s, 120s, ...
      # Registry and quota trouble does not clear in seconds, so those failures
      # back off from a longer base instead of burning attempts immediately.
      SLOW_RETRY_BASE = { "quota_exhausted" => 600, "registry_unavailable" => 120 }.freeze

      def self.retry_delay(attempts_made, code: nil)
        base = SLOW_RETRY_BASE.fetch(code.to_s, 30)
        (base * (2**[ attempts_made - 1, 0 ].max)).seconds
      end
    end
  end
end
