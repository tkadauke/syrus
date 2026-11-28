module RuntimeImages
  module Builds
    # Tunables for build admission and retries. Environment-overridable so
    # operators can size the plane without a deploy.
    module Config
      PLATFORMS = %w[linux/amd64 linux/arm64].freeze
      MAX_RECIPE_BYTES = 64.kilobytes

      def self.setting(key, env_key)
        configured = ENV[env_key]
        configured.present? ? configured : EnvironmentPolicy.value("builder", key)
      end

      def self.max_concurrent_builds = Integer(setting("max_concurrent_builds", "RUNTIME_IMAGE_BUILD_CONCURRENCY"))
      def self.max_concurrent_per_namespace = Integer(setting("max_concurrent_per_namespace", "RUNTIME_IMAGE_BUILD_NAMESPACE_CONCURRENCY"))
      def self.max_attempts = Integer(setting("max_attempts", "RUNTIME_IMAGE_BUILD_MAX_ATTEMPTS"))
      def self.lease_duration = Integer(ENV.fetch("RUNTIME_IMAGE_BUILD_LEASE_SECONDS", 1800)).seconds

      # Per-build ceilings enforced by the isolated builder.
      def self.build_cpus = Float(setting("cpus", "RUNTIME_IMAGE_BUILD_CPUS"))
      def self.build_memory_bytes = Integer(setting("memory_bytes", "RUNTIME_IMAGE_BUILD_MEMORY_BYTES"))
      def self.build_pids = Integer(setting("pids", "RUNTIME_IMAGE_BUILD_PIDS"))
      def self.build_storage_bytes = Integer(setting("storage_bytes", "RUNTIME_IMAGE_BUILD_STORAGE_BYTES"))
      def self.build_duration = Integer(setting("timeout_seconds", "RUNTIME_IMAGE_BUILD_TIMEOUT_SECONDS"))
      def self.build_log_bytes = Integer(setting("log_bytes", "RUNTIME_IMAGE_BUILD_LOG_BYTES"))
      def self.max_output_bytes = Integer(setting("max_output_bytes", "RUNTIME_IMAGE_BUILD_MAX_OUTPUT_BYTES"))
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
