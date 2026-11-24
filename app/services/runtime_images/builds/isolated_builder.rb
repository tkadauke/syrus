require "digest"
require "fileutils"
require "tmpdir"

module RuntimeImages
  module Builds
    # The socketless OCI builder. It drives a rootless buildah (chroot
    # isolation, no daemon, no container-engine socket) as an ordinary
    # ProcessRunner child, so the worker's Docker socket is never mounted or
    # reachable by the build.
    #
    # Isolation properties, each enforced here rather than assumed:
    #  - the child environment is built from an allowlist; nothing is inherited,
    #    so no repository, provider, coworker-memory, MCP, runtime-secret, or
    #    deployment-registry credential can reach a Dockerfile RUN step, and
    #    registry auth is pinned to an empty file;
    #  - the source is unpacked from the request's own archive into a private
    #    scratch directory; context and Dockerfile paths are checked against
    #    traversal and symlink escape;
    #  - layer storage is a per-namespace cache directory, never shared across
    #    namespaces, exclusive per build, and wiped once it outgrows its ceiling;
    #  - CPU, memory, PIDs, wall-clock duration, log volume, scratch/cache
    #    storage, and output archive size all have ceilings.
    class IsolatedBuilder
      # Fails closed when the worker cannot actually confine the build: a root
      # worker would run buildah rootful with the worker's host access, so an
      # unprivileged account is required unless the operator attests that the
      # worker itself is a disposable confined sandbox. Per-spawn cgroup
      # limits (memory/CPU) must also have been applied to each command.
      class Confinement
        def verify!
          if Process.euid.zero? && !Config.worker_confined?
            raise BuildFailed.new("builder refuses to run as root without RUNTIME_IMAGE_BUILD_WORKER_CONFINED=1",
                                  code: "builder_not_isolated", retryable: false)
          end
          return if system("prlimit", "--version", out: File::NULL, err: File::NULL)

          raise BuildFailed.new("prlimit is required to bound builder PIDs and storage", code: "builder_not_isolated", retryable: false)
        end

        def verify_applied!(result)
          return if Config.cgroup_optional?

          id = result.respond_to?(:spawned_process_id) ? result.spawned_process_id : nil
          # No spawned-process record means no cgroup was ever created: that is
          # an unconfined command, never a pass.
          state = id && SpawnedProcess.find_by(id: id)&.resource_attribution&.dig("cgroup", "state")
          return if state == "applied"

          raise BuildFailed.new("cgroup memory/CPU/PID limits were not applied (state=#{state.inspect})",
                                code: "builder_not_isolated", retryable: true)
        end
      end

      IMAGE_TAG = "runtime-image-build:latest".freeze
      ALLOWED_RECIPE_KEYS = %w[dockerfile context target build_args].freeze
      BUILD_ARG_NAME = /\A[A-Za-z_][A-Za-z0-9_]{0,63}\z/
      TARGET_NAME = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
      STORAGE_POLL_SECONDS = 5

      # Default launcher: a ProcessRunner invocation with an empty inherited env.
      Launcher = Struct.new(:network) do
        def call(command:, env:, mounts:, timeout:, resource_limits:, stop_requested:, on_output_chunk:)
          ProcessRunner.new(
            env: env, command: command, mounts: mounts, network: network, timeout: timeout,
            resource_limits: resource_limits, stop_requested: stop_requested, on_output_chunk: on_output_chunk,
            kind: "builder"
          ).run
        end
      end

      def initialize(launcher: Launcher.new("prepare"), data_root: nil, extractor: SourceExtractor.new,
                     confinement: Confinement.new)
        @launcher = launcher
        @confinement = confinement
        @data_root = data_root
        @extractor = extractor
      end

      def build(request:, attempt:, control:)
        @confinement.verify!
        recipe = validate_recipe!(request.recipe)
        build_root = root.join("builds")
        FileUtils.mkdir_p(build_root)
        Dir.mktmpdir("build-#{request.id}-", build_root.to_s) do |scratch|
          source_dir = File.join(scratch, "source")
          archive_digest = extract_source!(request, source_dir)
          context = resolve_context!(source_dir, request.source_manifest["context_path"], recipe)
          with_cache(request) do |cache|
            output = File.join(scratch, "image.tar")
            run_build(request, control, scratch: scratch, cache: cache, context: context, recipe: recipe, output: output)
            Output.new(payload: read_output!(output, request.platform), source_digest: request.source_digest,
                       provenance: provenance(request, archive_digest))
          end
        end
      rescue Rejected => e
        raise BuildFailed.new(e.message, code: e.code, retryable: false)
      end

      private

      def root
        @root ||= (@data_root || WorkflowWorkspace.data_root).join("runtime-image-builds")
      end

      def validate_recipe!(recipe)
        recipe = Hash(recipe).deep_stringify_keys
        unknown = recipe.keys - ALLOWED_RECIPE_KEYS
        raise Rejected.new("recipe_invalid", "unsupported recipe keys: #{unknown.sort.join(", ")}") if unknown.any?

        target = recipe["target"]
        raise Rejected.new("recipe_invalid", "invalid build target") if target && !target.to_s.match?(TARGET_NAME)
        args = Hash(recipe["build_args"])
        raise Rejected.new("recipe_invalid", "too many build args") if args.size > 64
        args.each do |name, value|
          raise Rejected.new("recipe_invalid", "invalid build arg name #{name.to_s.inspect}") unless name.to_s.match?(BUILD_ARG_NAME)
          raise Rejected.new("recipe_invalid", "build arg #{name} is too long") if value.to_s.bytesize > 4096 || value.to_s.include?("\0")
        end
        recipe
      end

      def extract_source!(request, dir)
        raise Rejected.new("source_missing", "build request has no source archive") unless request.source_archive.attached?

        archive = File.join(File.dirname(dir), "source.archive")
        File.binwrite(archive, request.source_archive.download)
        digest = @extractor.extract(archive, dir)
        revision = request.source_manifest["revision"].to_s
        if revision.start_with?("sha256:") && revision != digest
          raise Rejected.new("source_mismatch", "source archive digest #{digest} does not match captured #{revision}")
        end
        FileUtils.rm_f(archive)
        digest
      end

      def resolve_context!(source_dir, captured_context, recipe)
        context_rel = BuildPaths.relative!(recipe["context"] || captured_context || ".", what: "context path")
        context = BuildPaths.resolve!(source_dir, context_rel, what: "context path")
        raise Rejected.new("path_invalid", "context path is not a directory") unless File.directory?(context)

        dockerfile_rel = BuildPaths.relative!(recipe["dockerfile"] || "Dockerfile", what: "Dockerfile path")
        dockerfile = BuildPaths.resolve!(context, dockerfile_rel, what: "Dockerfile path")
        raise Rejected.new("path_invalid", "Dockerfile is not a regular file") unless File.file?(dockerfile)

        { dir: context, dockerfile: dockerfile }
      end

      # Exclusive, namespace-scoped layer cache. A concurrent build of the same
      # namespace backs off and retries rather than sharing mutable storage.
      def with_cache(request)
        cache = root.join("cache", "ns-#{request.runtime_image_namespace_id}")
        FileUtils.mkdir_p(cache)
        File.open(cache.join(".lock").to_s, File::RDWR | File::CREAT, 0o600) do |lock|
          unless lock.flock(File::LOCK_EX | File::LOCK_NB)
            raise BuildFailed.new("namespace build cache is in use", code: "cache_busy", retryable: true)
          end
          if directory_bytes(cache.to_s, limit: Config.cache_max_bytes + 1) > Config.cache_max_bytes
            FileUtils.rm_rf(Dir.children(cache).reject { |n| n == ".lock" }.map { |n| cache.join(n).to_s })
          end
          yield cache.to_s
        end
      end

      def run_build(request, control, scratch:, cache:, context:, recipe:, output:)
        deadline = monotonic + Config.build_duration
        logged = 0
        failure = nil
        last_poll = 0.0
        stop = lambda do
          now = monotonic
          failure ||= [ "build_cancelled", "build was canceled" ] if control.cancel_requested?
          if now - last_poll >= STORAGE_POLL_SECONDS
            last_poll = now
            control.heartbeat
            failure ||= storage_failure(scratch, cache)
          end
          !failure.nil?
        end
        on_chunk = lambda do |chunk|
          logged += chunk.bytesize
          failure ||= [ "log_limit_exceeded", "build log exceeded #{Config.build_log_bytes} bytes" ] if logged > Config.build_log_bytes
        end

        [ build_command(request, cache, context, recipe), push_command(cache, output) ].each do |inner|
          command = limited(inner)
          remaining = deadline - monotonic
          raise BuildFailed.new("build exceeded #{Config.build_duration}s", code: "build_timeout") unless remaining.positive?

          result = @launcher.call(command: command, env: environment(scratch), mounts: mounts(scratch, cache),
                                  timeout: remaining, resource_limits: resource_limits, stop_requested: stop, on_output_chunk: on_chunk)
          control.raise_if_canceled!
          @confinement.verify_applied!(result)
          check_storage!(scratch, cache)
          raise BuildFailed.new(failure.last, code: failure.first) if failure
          raise BuildFailed.new("build exceeded #{Config.build_duration}s", code: "build_timeout") if result.timed_out?
          raise BuildFailed.new("build was stopped", code: "build_stopped", retryable: true) if result.stopped? || result.operator_killed?
          raise BuildFailed.new("build exited with status #{result.exit_status}", code: "build_failed") unless result.success?
        end
      end

      # Hard per-process ceilings inherited by the whole builder tree for both
      # build and push: process count, largest single file (so one write cannot
      # blow past the storage ceiling between samples), and CPU seconds.
      def limited(command)
        [ "prlimit", "--nproc=#{Config.build_pids}", "--fsize=#{Config.build_storage_bytes}",
          "--cpu=#{Config.build_duration * [ Config.build_cpus.ceil, 1 ].max}", "--", *command ]
      end

      def storage_failure(scratch, cache)
        limit = Config.build_storage_bytes
        used = directory_bytes(scratch, limit: limit + 1) + directory_bytes(cache, limit: limit + 1)
        [ "storage_limit_exceeded", "build exceeded #{limit} bytes of storage" ] if used > limit
      end

      # Mandatory after every command, so a build that overshoots between
      # samples and exits is still rejected.
      def check_storage!(scratch, cache)
        failure = storage_failure(scratch, cache)
        raise BuildFailed.new(failure.last, code: failure.first) if failure
      end

      def build_command(request, cache, context, recipe)
        cmd = [ *base(cache), "build", "--isolation", "chroot", "--platform", request.platform, "--format", "oci",
                "--layers=false", "--memory", Config.build_memory_bytes.to_s,
                "--cpu-period", "100000", "--cpu-quota", (Config.build_cpus * 100_000).to_i.to_s,
                "--ulimit", "nproc=#{Config.build_pids}:#{Config.build_pids}",
                "--file", context[:dockerfile], "--tag", IMAGE_TAG ]
        cmd += [ "--target", recipe["target"].to_s ] if recipe["target"]
        Hash(recipe["build_args"]).sort.each { |name, value| cmd += [ "--build-arg", "#{name}=#{value}" ] }
        cmd << context[:dir]
      end

      def push_command(cache, output) = [ *base(cache), "push", IMAGE_TAG, "oci-archive:#{output}" ]

      def base(cache)
        [ Config.build_binary, "--root", File.join(cache, "storage"), "--runroot", File.join(cache, "run"),
          "--storage-driver", Config.storage_driver ]
      end

      # Allowlist only. No registry auth file, no inherited credentials.
      def environment(scratch)
        { "PATH" => "/usr/local/bin:/usr/bin:/bin", "HOME" => scratch, "TMPDIR" => scratch, "LANG" => "C.UTF-8",
          "REGISTRY_AUTH_FILE" => File::NULL, "DOCKER_CONFIG" => File.join(scratch, "no-docker-config") }
      end

      def mounts(scratch, cache) = ProcessRunner::Mounts.new(workdir: scratch, read_write: [ scratch, cache ])

      def resource_limits
        Execution::ResourceLimits.new(memory_max: Config.build_memory_bytes,
                                      cpu_max: "#{(Config.build_cpus * 100_000).to_i} 100000", io_weight: nil,
                                      pids_max: Config.build_pids)
      end

      def read_output!(path, platform)
        raise BuildFailed.new("build produced no image archive", code: "no_output") unless File.file?(path)
        size = File.size(path)
        if size > Config.max_output_bytes
          raise BuildFailed.new("image archive is #{size} bytes, over the #{Config.max_output_bytes} byte ceiling", code: "output_too_large")
        end
        WorkerCache::OciArchive.read(path, platform: platform)
      rescue WorkerCache::EngineError => e
        raise BuildFailed.new(e.message, code: "output_invalid")
      end

      def provenance(request, archive_digest)
        { "builder" => "buildah-rootless", "isolation" => "chroot", "source_archive_digest" => archive_digest,
          "recipe_digest" => request.recipe_digest }
      end

      # Sum of file sizes, stopping early once +limit+ is passed.
      def directory_bytes(dir, limit:)
        total = 0
        Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).each do |path|
          total += File.lstat(path).size if File.file?(path) && !File.symlink?(path)
          return total if total >= limit
        rescue SystemCallError
          next
        end
        total
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
