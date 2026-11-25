module RuntimeImages
  module Builds
    # In-memory evidence an attempt accumulates while it runs. The builder fills
    # it in as facts become known (including on a path that later fails), and
    # EvidenceRecorder persists it once the attempt reaches a terminal state.
    # Nothing here is secret: logs are sanitized on the way in and the network
    # record holds names, ports, and resolved addresses only.
    class Evidence
      attr_reader :log, :base_images, :destinations, :layer_digests, :resources
      attr_accessor :builder_version, :policy_digest, :policy_snapshot, :image_digest

      def initialize(log: LogCapture.new)
        @log = log
        @base_images = []
        @destinations = []
        @layer_digests = []
        @policy_snapshot = []
        @resources = { "limits" => limits }
        @network = {}
      end

      def record_network(policy, summary)
        @policy_digest = policy.digest
        @policy_snapshot = policy.snapshot
        @network = summary.is_a?(Hash) ? summary : {}
        @destinations = Array(@network["destinations"])
        @resources["network"] = { "allowed" => @network.fetch("allowed", 0), "denied" => @network.fetch("denied", 0) }
      end

      def denials = Array(@network["denials"])

      # +references+ are the FROM references of the Dockerfile; +images+ is the
      # builder's own listing of what it resolved ({"names" => [...], "digest" => ...}).
      def record_bases(references, images)
        @base_images = DockerfileBases.resolve(references, images)
      end

      def record_process(result)
        @resources["duration_seconds"] = result.duration_s.to_f.round(2) if result.respond_to?(:duration_s) && result.duration_s
        @resources["exit_status"] = result.exit_status if result.respond_to?(:exit_status)
        id = result.respond_to?(:spawned_process_id) ? result.spawned_process_id : nil
        cgroup = id && SpawnedProcess.find_by(id: id)&.resource_attribution&.dig("cgroup")
        @resources["cgroup"] = measured(cgroup) if cgroup.is_a?(Hash)
      end

      def record_scratch(bytes)
        @resources["peak_scratch_bytes"] = [ @resources["peak_scratch_bytes"].to_i, bytes.to_i ].max
      end

      def record_output(bytes) = @resources["output_bytes"] = bytes.to_i

      # Layer digests come from the manifest of the image about to be published.
      def record_image(payload)
        manifest = payload.is_a?(Hash) ? payload[:manifest] : nil
        parsed = manifest.is_a?(String) ? JSON.parse(manifest) : nil
        @layer_digests = Array(parsed.is_a?(Hash) ? parsed["layers"] : nil).filter_map { |layer| layer["digest"] if layer.is_a?(Hash) }
        @resources["layer_count"] = @layer_digests.size
      rescue JSON::ParserError
        @layer_digests = []
      end

      def finalize_log
        text = log.finish
        @resources["log_bytes_seen"] = log.seen_bytes
        text
      end

      private

      def limits
        { "cpus" => Config.build_cpus, "memory_bytes" => Config.build_memory_bytes, "pids" => Config.build_pids,
          "storage_bytes" => Config.build_storage_bytes, "duration_seconds" => Config.build_duration,
          "log_bytes" => Config.build_log_bytes, "output_bytes" => Config.max_output_bytes }
      end

      def measured(cgroup)
        events = cgroup["memory_events"].is_a?(Hash) ? cgroup["memory_events"] : {}
        cpu = cgroup["cpu_stat"].is_a?(Hash) ? cgroup["cpu_stat"] : {}
        { "state" => cgroup["state"], "memory_peak_bytes" => cgroup["memory_peak_bytes"],
          "cpu_usage_usec" => cpu["usage_usec"], "cpu_user_usec" => cpu["user_usec"], "cpu_system_usec" => cpu["system_usec"],
          "cpu_throttled_usec" => cpu["throttled_usec"], "oom_kill" => events["oom_kill"], "io_stat" => cgroup["io_stat"] }.compact
      end
    end
  end
end
