require "digest"
require "fileutils"
require "shellwords"
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
    #  - layer storage and the build's HOME/TMPDIR live on a size-bounded tmpfs
    #    mounted inside a private user+mount namespace, so aggregate scratch
    #    usage has a kernel-enforced ceiling (ENOSPC), is never shared across
    #    builds or namespaces, and vanishes with the namespace;
    #  - the build runs in an empty network namespace (loopback only); its sole
    #    route out is a relay to BuildNetwork::Proxy, which enforces the
    #    administrator's allowlist, so host and shared network modes do not
    #    exist for a build and direct egress is impossible;
    #  - CPU, memory, PIDs, wall-clock duration, log volume, scratch
    #    storage, and output archive size all have ceilings.
    class IsolatedBuilder
      MIN_TMPFS_BYTES = 4096
      EXTRACT_SCRIPT = Rails.root.join("bin/extract-runtime-image-source")
      REJECT_FILE = "source.rejected.json"
      NAMESPACE_PREFIX = %w[unshare --user --map-root-user --mount --].freeze
      # The build's own namespace has no network device but a loopback; its only
      # route out is the relay to the enforcing proxy.
      BUILD_NAMESPACE_PREFIX = %w[unshare --user --map-root-user --mount --net --].freeze
      FORBIDDEN_NETWORK_KEYS = %w[network network_mode net add_host dns dns_search dns_option proxy].freeze
      PROXY_BUILD_ARG = /\A(http|https|ftp|all|no)_proxy\z/i

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
          unless probe("prlimit", "--version")
            raise BuildFailed.new("prlimit is required to bound builder file sizes and CPU", code: "builder_not_isolated", retryable: false)
          end
          unless bounded_storage_available?
            raise BuildFailed.new("unprivileged user+mount namespaces with a size-bounded tmpfs are required to bound builder storage",
                                  code: "builder_not_isolated", retryable: false)
          end
          return if isolated_network_available?

          raise BuildFailed.new("an unprivileged network namespace with only a loopback device is required to enforce build egress",
                                code: "builder_not_isolated", retryable: false)
        end

        # The namespace the build runs in must start with loopback as its only
        # device; anything more would be a route around the egress proxy.
        def isolated_network_available?
          probe(*BUILD_NAMESPACE_PREFIX, "sh", "-c", "ip link set lo up && test \"$(ip -o link show | wc -l)\" = 1")
        end

        # Probes the exact mechanism the build relies on for its hard aggregate
        # storage ceiling; unavailable means no bounded storage, so no build.
        def bounded_storage_available?
          Dir.mktmpdir("rib-probe") do |dir|
            probe(*NAMESPACE_PREFIX, "sh", "-c", "mount -t tmpfs -o size=1m tmpfs \"$1\" && : > \"$1/probe\"", "sh", dir,
                  read_write: dir)
          end
        end

        # Runs a short capability probe through ProcessRunner (the single
        # process-launch door); true only on a zero exit.
        def probe(*command, read_write: nil)
          workdir = read_write || Dir.tmpdir
          ProcessRunner.new(
            env: { "PATH" => ENV.fetch("PATH", "/usr/local/bin:/usr/bin:/bin") },
            command: command,
            mounts: ProcessRunner.mounts(workdir, read_write: read_write || []),
            network: "grader",
            timeout: 15
          ).run.success?
        rescue StandardError
          false
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

      def initialize(launcher: Launcher.new("prepare"), data_root: nil, confinement: Confinement.new,
                     network_policy: -> { BuildNetwork::Policy.current }, resolver: BuildNetwork::Resolver.new)
        @launcher = launcher
        @confinement = confinement
        @data_root = data_root
        @network_policy = network_policy
        @resolver = resolver
      end

      def build(request:, attempt:, control:)
        @confinement.verify!
        recipe = validate_recipe!(request.recipe)
        build_root = root.join("builds")
        FileUtils.mkdir_p(build_root)
        Dir.mktmpdir("build-#{request.id}-", build_root.to_s) do |scratch|
          archive_digest = stage_source!(request, scratch)
          output = File.join(scratch, "image.tar")
          policy = @network_policy.call
          session = nil
          begin
            BuildNetwork::Session.open(policy: policy, resolver: @resolver) do |opened|
              session = opened
              run_build(request, control, scratch: scratch, recipe: recipe, output: output,
                                          recipe_paths: context_paths(request, recipe), network: opened)
            end
          ensure
            # Counters outlive the stopped proxy, so a failed build is audited too.
            audit_network(request, policy, session&.summary)
          end
          Output.new(payload: read_output!(output, request.platform), source_digest: request.source_digest,
                     provenance: provenance(request, archive_digest, policy))
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
        forbidden = recipe.keys & FORBIDDEN_NETWORK_KEYS
        if forbidden.any?
          raise Rejected.new("network_mode_forbidden", "builds cannot choose their network: #{forbidden.sort.join(", ")}")
        end
        unknown = recipe.keys - ALLOWED_RECIPE_KEYS
        raise Rejected.new("recipe_invalid", "unsupported recipe keys: #{unknown.sort.join(", ")}") if unknown.any?

        target = recipe["target"]
        raise Rejected.new("recipe_invalid", "invalid build target") if target && !target.to_s.match?(TARGET_NAME)
        args = Hash(recipe["build_args"])
        raise Rejected.new("recipe_invalid", "too many build args") if args.size > 64
        args.each do |name, value|
          raise Rejected.new("recipe_invalid", "invalid build arg name #{name.to_s.inspect}") unless name.to_s.match?(BUILD_ARG_NAME)
          if name.to_s.match?(PROXY_BUILD_ARG)
            raise Rejected.new("network_mode_forbidden", "build arg #{name} would override the build's egress proxy")
          end
          raise Rejected.new("recipe_invalid", "build arg #{name} is too long") if value.to_s.bytesize > 4096 || value.to_s.include?("\0")
        end
        recipe
      end

      # Downloads the raw archive (one file, capped by the source and storage
      # ceilings) to host scratch and checks it against the captured digest.
      # Unpacking happens later, inside the bounded tmpfs namespace.
      def stage_source!(request, scratch)
        raise Rejected.new("source_missing", "build request has no source archive") unless request.source_archive.attached?

        archive = File.join(scratch, "source.archive")
        blob = request.source_archive.blob
        ceiling = [ Config.max_source_bytes, Config.build_storage_bytes ].min
        if blob.byte_size > ceiling
          raise Rejected.new("source_too_large", "source archive is #{blob.byte_size} bytes, over the #{ceiling} byte limit")
        end

        # Stream in chunks with a running cap so the archive is never fully
        # materialized in the worker heap, and a lying byte_size cannot overrun.
        written = 0
        File.open(archive, "wb") do |file|
          blob.download do |chunk|
            written += chunk.bytesize
            raise Rejected.new("source_too_large", "source archive exceeds the #{ceiling} byte limit") if written > ceiling

            file.write(chunk)
          end
        end
        digest = "sha256:#{Digest::SHA256.file(archive).hexdigest}"
        revision = request.source_manifest["revision"].to_s
        if revision.start_with?("sha256:") && revision != digest
          raise Rejected.new("source_mismatch", "source archive digest #{digest} does not match captured #{revision}")
        end
        digest
      end

      # Lexically validated context and Dockerfile paths; resolution against
      # the real tree (symlink escape) happens in the extraction script.
      def context_paths(request, recipe)
        context = BuildPaths.relative!(recipe["context"] || request.source_manifest["context_path"] || ".", what: "context path")
        dockerfile = BuildPaths.relative!(recipe["dockerfile"] || "Dockerfile", what: "Dockerfile path")
        [ context, dockerfile ]
      end

      # One command for the whole build: build and push share the bounded
      # tmpfs (it only exists inside the namespace), and the process tree is
      # bounded by prlimit plus the per-spawn cgroup.
      def run_build(request, control, scratch:, recipe:, output:, recipe_paths:, network:)
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
            failure ||= storage_failure(scratch)
          end
          !failure.nil?
        end
        on_chunk = lambda do |chunk|
          logged += chunk.bytesize
          failure ||= [ "log_limit_exceeded", "build log exceeded #{Config.build_log_bytes} bytes" ] if logged > Config.build_log_bytes
        end

        work = File.join(scratch, "work")
        FileUtils.mkdir_p(work)
        command = limited(wrapped(scratch, work, recipe_paths, build_command(request, work, recipe), push_command(work, output), network))
        remaining = deadline - monotonic
        raise BuildFailed.new("build exceeded #{Config.build_duration}s", code: "build_timeout") unless remaining.positive?

        result = @launcher.call(command: command, env: environment(work).merge(network.environment), mounts: mounts(scratch, network),
                                timeout: remaining, resource_limits: resource_limits, stop_requested: stop, on_output_chunk: on_chunk)
        control.raise_if_canceled!
        @confinement.verify_applied!(result)
        raise_if_source_rejected!(scratch)
        check_storage!(scratch)
        raise BuildFailed.new(failure.last, code: failure.first) if failure
        raise BuildFailed.new("build exceeded #{Config.build_duration}s", code: "build_timeout") if result.timed_out?
        raise BuildFailed.new("build was stopped", code: "build_stopped", retryable: true) if result.stopped? || result.operator_killed?
        raise BuildFailed.new("build exited with status #{result.exit_status}", code: "build_failed") unless result.success?
      end

      # Mounts a size-bounded tmpfs at +work+ inside a private user+mount
      # namespace, unpacks the source onto it, then runs build and push against
      # it. Writes past the size fail with ENOSPC in the kernel; nothing but the
      # one raw archive is left on the host disk.
      def wrapped(scratch, work, paths, build, push, network)
        extract = [ RbConfig.ruby, EXTRACT_SCRIPT.to_s, File.join(scratch, "source.archive"), File.join(work, "source"), work,
                    File.join(scratch, REJECT_FILE), Config.max_source_bytes.to_s, Config.max_source_entries.to_s, *paths ]
        script = "set -eu; mount -t tmpfs -o size=#{tmpfs_bytes(scratch)},mode=0700 tmpfs #{Shellwords.escape(work)}; " \
                 "mkdir -p #{Shellwords.escape(File.join(work, "home"))} #{Shellwords.escape(File.join(work, "tmp"))}; " \
                 "ip link set lo up; #{Shellwords.join(network.relay_command)} & relay=$!; " \
                 "trap 'kill $relay 2>/dev/null || true' EXIT; " \
                 "#{Shellwords.join(extract)}; " \
                 "#{Shellwords.join(build)} && #{Shellwords.join(push)}"
        [ *BUILD_NAMESPACE_PREFIX, "sh", "-c", script ]
      end

      # The staged archive stays on host disk for the whole build, so the tmpfs
      # only gets what is left of the aggregate storage ceiling after the
      # archive's actual allocation (blocks, not logical bytes). Archive plus
      # tmpfs capacity therefore never exceeds build_storage_bytes.
      def tmpfs_bytes(scratch)
        stat = File.stat(File.join(scratch, "source.archive"))
        used = [ stat.size, stat.blocks.to_i * 512 ].max
        remaining = Config.build_storage_bytes - used
        if remaining < MIN_TMPFS_BYTES
          raise Rejected.new("source_too_large", "source archive leaves no room for the build within the #{Config.build_storage_bytes} byte storage ceiling")
        end
        remaining
      end

      def raise_if_source_rejected!(scratch)
        path = File.join(scratch, REJECT_FILE)
        return unless File.exist?(path)

        info = JSON.parse(File.read(path))
        raise BuildFailed.new(info["message"].to_s, code: info["code"].to_s, retryable: false)
      end

      # Hard per-process ceilings inherited by the whole builder tree: process
      # count, largest single file (the output archive lives outside the tmpfs),
      # and CPU seconds.
      def limited(command)
        [ "prlimit", "--nproc=#{Config.build_pids}", "--fsize=#{[ Config.build_storage_bytes, Config.max_output_bytes ].max}",
          "--cpu=#{Config.build_duration * [ Config.build_cpus.ceil, 1 ].max}", "--", *command ]
      end

      # Source and output archive live on the host scratch (outside the tmpfs);
      # they are bounded by the source ceilings and RLIMIT_FSIZE, and re-checked
      # after the command.
      def storage_failure(scratch)
        limit = Config.build_storage_bytes
        used = directory_bytes(scratch, limit: limit + 1)
        [ "storage_limit_exceeded", "build exceeded #{limit} bytes of storage" ] if used > limit
      end

      def check_storage!(scratch)
        failure = storage_failure(scratch)
        raise BuildFailed.new(failure.last, code: failure.first) if failure
      end

      def build_command(request, work, recipe)
        cmd = [ *base(work), "build", "--isolation", "chroot", "--platform", request.platform, "--format", "oci",
                "--layers=false", "--memory", Config.build_memory_bytes.to_s,
                "--cpu-period", "100000", "--cpu-quota", (Config.build_cpus * 100_000).to_i.to_s,
                "--ulimit", "nproc=#{Config.build_pids}:#{Config.build_pids}",
                "--file", File.join(work, "dockerfile"), "--tag", IMAGE_TAG ]
        cmd += [ "--target", recipe["target"].to_s ] if recipe["target"]
        Hash(recipe["build_args"]).sort.each { |name, value| cmd += [ "--build-arg", "#{name}=#{value}" ] }
        cmd << File.join(work, "context")
      end

      def push_command(work, output) = [ *base(work), "push", IMAGE_TAG, "oci-archive:#{output}" ]

      def base(work)
        [ Config.build_binary, "--root", File.join(work, "storage"), "--runroot", File.join(work, "run"),
          "--storage-driver", Config.storage_driver ]
      end

      # Allowlist only. No registry auth file, no inherited credentials.
      def environment(work)
        { "PATH" => "/usr/local/bin:/usr/bin:/bin", "HOME" => File.join(work, "home"), "TMPDIR" => File.join(work, "tmp"),
          "LANG" => "C.UTF-8", "REGISTRY_AUTH_FILE" => File::NULL, "DOCKER_CONFIG" => File.join(work, "no-docker-config") }
      end

      def mounts(scratch, network) = ProcessRunner::Mounts.new(workdir: scratch, read_write: [ scratch, network.dir ])

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

      def provenance(request, archive_digest, policy)
        { "builder" => "buildah-rootless", "isolation" => "chroot", "source_archive_digest" => archive_digest,
          "recipe_digest" => request.recipe_digest, "network_policy_digest" => policy.digest }
      end

      # Records what the build tried to reach. +summary+ is nil when the build
      # failed before the proxy could report; the policy digest is still logged.
      def audit_network(request, policy, summary)
        summary = {} unless summary.is_a?(Hash) && summary.key?("allowed")
        denied = summary.fetch("denied", 0)
        Audit.record("build.network", outcome: denied.positive? ? "detected" : "ok", namespace: request.runtime_image_namespace,
                                      actor: request.requester_kind,
                                      details: { "request_id" => request.id, "policy_digest" => policy.digest,
                                                 "allowed" => summary.fetch("allowed", 0), "denied" => denied,
                                                 "denials" => summary.fetch("denials", []).first(10).to_json })
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
