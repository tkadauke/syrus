require "json"
require "tmpdir"

module RuntimeImages
  class WorkerCache
    # Engine backed by a docker-compatible CLI (docker, podman). Registry
    # auth, when given, is written to a throwaway DOCKER_CONFIG so the
    # pull-only token never lands in the worker's long-lived login state.
    class CliEngine < Engine
      def initialize(binary: "docker", cache_path: "/var/lib/docker")
        @binary = binary
        @cache_path = cache_path
      end

      def pull(reference, timeout:, auth: nil)
        with_config(auth, reference) do |env|
          out, status, timed_out = run(env, "pull", reference, timeout: timeout)
          raise EngineTimeout, "pull of #{reference} exceeded #{timeout}s" if timed_out
          raise EngineError, "pull of #{reference} failed: #{out.to_s.lines.last.to_s.strip}" unless status&.success?
        end
      end

      def digests(reference)
        out, status, = run({}, "image", "inspect", "--format", "{{json .RepoDigests}}", reference, timeout: 30)
        return [] unless status&.success?
        Array(JSON.parse(out.to_s.strip)).filter_map { |entry| entry.to_s.split("@", 2)[1] }
      rescue JSON::ParserError
        []
      end

      def size_bytes(reference)
        out, status, = run({}, "image", "inspect", "--format", "{{.Size}}", reference, timeout: 30)
        status&.success? ? out.to_s.strip.to_i : nil
      end

      def remove(reference)
        out, status, = run({}, "image", "rm", reference, timeout: 120)
        raise EngineError, "could not remove #{reference}: #{out.to_s.strip}" unless status&.success?
      end

      def disk_usage
        capture = execute({}, "df", "-Pk", @cache_path, timeout: 30)
        raise EngineError, "df failed for #{@cache_path}" unless capture.result.success?
        _fs, blocks, _used, avail = capture.stdout.lines.last.split
        { total_bytes: blocks.to_i * 1024, free_bytes: avail.to_i * 1024 }
      end

      private

      def with_config(auth, reference)
        return yield({}) unless auth
        Dir.mktmpdir("runtime-image-pull") do |dir|
          host = reference.to_s.split("/", 2).first
          File.write(File.join(dir, "config.json"), JSON.generate("auths" => { host => { "registrytoken" => auth.fetch(:token) } }))
          File.chmod(0o600, File.join(dir, "config.json"))
          yield("DOCKER_CONFIG" => dir)
        end
      end

      def run(env, *args, timeout:)
        capture = execute(env, @binary, *args, timeout: timeout)
        result = capture.result
        [capture.stdout.to_s + capture.stderr.to_s, result.timed_out? ? nil : ProcessStatus.new(result.success?), result.timed_out?]
      end

      ProcessStatus = Data.define(:success) do
        def success? = success
      end

      # Process launches go through ProcessRunner like every other production
      # command; the scratch workdir is a probe directory, not a workspace.
      def execute(env, *command, timeout:)
        ProcessRunner.new(
          env: forwarded_env.merge(env),
          command: command,
          mounts: ProcessRunner.probe_mounts,
          network: "prepare",
          timeout: timeout
        ).capture(limit: 64.kilobytes)
      end

      def forwarded_env
        ENV.slice("PATH", "HOME", "DOCKER_HOST", "XDG_RUNTIME_DIR").compact
      end
    end
  end
end
