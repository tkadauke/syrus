# frozen_string_literal: true

module Deploy
  # Build, push and prove the images this revision deploys.
  #
  # Two images come out of one Dockerfile: `app` for the web pod, and
  # `worker-dev` for the worker pods, which carries mise and the multi-language
  # toolchain so the agent running inside a pod can actually verify its own
  # changes. Container-backed plugins (plugins/*/container) add one service
  # image each, pinned to the same revision as the backend.
  class Images
    attr_reader :config, :repo, :shell, :reporter

    def initialize(config:, repo:, shell:, reporter:)
      @config = config
      @repo = repo
      @shell = shell
      @reporter = reporter
      @build_started_at = Time.now.to_i
    end

    # [dir, registry] per container-backed plugin, from the one helper every
    # script that publishes these images shares. The naming rule has to live in
    # exactly one place or a deploy pushes an image the cluster's manifests name
    # differently.
    def plugin_images
      @plugin_images ||= shell
        .docker_lib("syrus_plugin_images", config.plugin_registry_root, mode: :read)
        .out
        .lines
        .map { |line| line.split.first(2) }
        .reject(&:empty?)
    end

    def plugin_registries
      plugin_images.map(&:last)
    end

    def all_registries
      [ config.registry, config.worker_dev_registry, *plugin_registries ]
    end

    def sha
      repo.sha
    end

    def ensure_available!
      login!
      config.skip_build ? verify_existing! : build_and_push!
    end

    private

    def login!
      reporter.step("#{config.registry} login")
      token = shell.docker_lib(
        "syrus_read_ghcr_token",
        config.ghcr_token_file,
        env: { "GHCR_TOKEN" => config.env["GHCR_TOKEN"] }.compact,
        mode: :read
      )
      raise Failure.new("no GHCR token found", detail: token.stderr) unless token.success?

      # The token travels in the environment, never in argv. Everything a
      # phase passes as an argument is eligible to be written to the dry run's
      # command stream, and that stream is a file an operator diffs and keeps.
      result = shell.write(
        [ "bash", "-c", <<~SH ],
          set -euo pipefail
          . bin/docker-image-lib
          syrus_ghcr_login "$GHCR_USER" "$GHCR_TOKEN"
        SH
        env: { "GHCR_USER" => config.ghcr_user, "GHCR_TOKEN" => token.out }
      )
      raise Failure.new("GHCR login failed", detail: result.stderr) unless result.success?
    end

    # `--skip-build` still has to prove the tags exist. It used to skip the
    # login that lives on the build path, so verification ran with no
    # credentials and failed on every tag -- including tags a previous run had
    # definitely pushed.
    def verify_existing!
      reporter.step("skipping build/push (--skip-build); verifying existing tags in registry")
      all_registries.each { |registry| verify_pushed!(registry, sha) }
    end

    def build_and_push!
      reclaim_disk!

      build_backend!
      build_worker_dev!
      plugin_images.each { |dir, registry| build_plugin!(dir, registry) }

      prune_old_tags!
      shell.docker_lib("syrus_docker_prune_build_cache_since", @build_started_at)
    end

    # Before the build, not only after it. The post-build prune only runs once
    # every build, push and verify has succeeded, so a deploy that dies partway
    # leaves its own images and the previous deploy's behind. Each worker-dev
    # image is ~16GB, so two failed deploys fill a 100GB Colima volume and the
    # next deploy fails on ENOSPC deep inside a layer extraction -- a ratchet
    # where running out of disk is what prevents the cleanup that would have
    # freed it. The helper never touches `:latest` or the tag being built, only
    # other revisions, which are already in the registry and re-pullable.
    def reclaim_disk!
      prune_old_tags!
      shell.docker_lib("syrus_docker_reclaim_for_preflight")
      result = shell.docker_lib("syrus_docker_require_free_space")
      raise Failure.new("not enough free space for a build") unless result.success?
    end

    def prune_old_tags!
      shell.docker_lib("syrus_docker_prune_old_repo_tags", sha, *all_registries)
    end

    def build_backend!
      pull_build_cache("#{config.registry}:latest")
      reporter.step("#{config.registry}:#{sha} build (linux/amd64, target=app)")
      build!("app", config.registry)
      push!(config.registry)
    end

    def build_worker_dev!
      pull_build_cache("#{config.worker_dev_registry}:latest")
      reporter.step("#{config.worker_dev_registry}:#{sha} build (linux/amd64, target=worker-dev)")
      build!("worker-dev", config.worker_dev_registry)
      # Prove the toolchain layer survived the build before anything in a
      # cluster depends on it. The same check runs again against a live pod
      # after the rollout; this one fails before the image is pushed.
      smoke = shell.docker_lib("syrus_worker_native_build_smoke", "#{config.worker_dev_registry}:#{sha}")
      raise Failure.new("#{config.worker_dev_registry}:#{sha} cannot compile a native extension") unless smoke.success?

      push!(config.worker_dev_registry)
    end

    # An unchanged plugin image is re-tagged in the registry rather than
    # rebuilt. These are small, independent services whose source rarely moves,
    # and rebuilding one unchanged image costs more than the whole backend push.
    def build_plugin!(dir, registry)
      base = image_base_sha
      if base && repo.paths_unchanged_since?(base, dir) && reuse_from_base(registry, base)
        return
      end

      pull_build_cache("#{registry}:latest")
      reporter.step("#{registry}:#{sha} build (linux/amd64)")
      run_docker!([
        "docker", "build", "--platform", "linux/amd64", "--provenance=false", "--sbom=false",
        *inline_cache_args("#{registry}:latest"),
        "-t", "#{registry}:#{sha}", "-t", "#{registry}:latest", dir
      ])
      push!(registry)
    end

    def reuse_from_base(registry, base)
      return false unless pushed?(registry, base)

      reporter.step("#{registry}:#{sha} unchanged since #{base}; reusing registry image")
      result = shell.stream_write([
        "docker", "buildx", "imagetools", "create",
        "--tag", "#{registry}:#{sha}", "--tag", "#{registry}:latest",
        "#{registry}:#{base}"
      ])
      return false unless result.success?

      verify_pushed!(registry, sha)
      verify_pushed!(registry, "latest")
      true
    end

    def image_base_sha
      return @image_base_sha if defined?(@image_base_sha)

      @image_base_sha = repo.image_base_sha(
        prefer_production: config.production,
        prefer_staging: config.staging
      )
    end

    def build!(target, registry)
      result = shell.docker_lib(
        "syrus_docker_build_image", target, sha,
        "--platform", "linux/amd64", "--provenance=false", "--sbom=false",
        *inline_cache_args("#{registry}:latest"),
        "-t", "#{registry}:#{sha}", "-t", "#{registry}:latest", "."
      )
      raise Failure.new("#{registry}:#{sha} build failed") unless result.success?
    end

    def push!(registry)
      reporter.step("#{registry}:#{sha} push")
      [ sha, "latest" ].each do |tag|
        run_docker!([ "docker", "push", "#{registry}:#{tag}" ])
        verify_pushed!(registry, tag)
      end
    end

    def run_docker!(argv)
      result = shell.stream_write(argv)
      raise Failure.new("#{argv.take(2).join(" ")} failed", detail: argv.join(" ")) unless result.success?
    end

    # A registry exporter has been seen to hang, or to return without having
    # produced a manifest at the tag. The only reliable signal is asking the
    # registry. Without this the deploy reports success and the rollout either
    # reuses the previous `:latest` digest -- a silent regression -- or
    # ImagePullBackOffs on a tag that was never written.
    def verify_pushed!(registry, tag)
      return if pushed?(registry, tag)

      raise Failure.new("#{registry}:#{tag} is not in the registry — the push did not land")
    end

    def pushed?(registry, tag)
      result = shell.docker_lib("syrus_verify_pushed", registry, tag, mode: :write)
      # A dry run implies --skip-build, so there is no push for this to
      # witness. Recording the question and answering yes keeps the phases
      # downstream behaving as they would against a registry that had the tag.
      shell.dry_run? || result.success?
    end

    def inline_cache_args(cache_image)
      return [] unless config.inline_cache?

      [ "--build-arg", "BUILDKIT_INLINE_CACHE=1", "--cache-from", cache_image ]
    end

    # `--cache-from` against a registry image only works when that image
    # carries inline cache metadata, so the pull, the flag and the build-arg
    # are one feature and switch together.
    def pull_build_cache(image)
      unless config.inline_cache?
        reporter.step("#{image}: registry-backed build cache disabled (SYRUS_DEPLOY_INLINE_CACHE=1 to enable)")
        return
      end

      reporter.step("#{image}: loading registry-backed build cache")
      shell.stream_write([ "docker", "pull", image ])
    end
  end
end
