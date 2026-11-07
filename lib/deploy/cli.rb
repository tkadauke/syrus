# frozen_string_literal: true

module Deploy
  # Argument parsing and the help text, kept away from the orchestration so
  # both can be read without the other.
  class CLI
    USAGE = <<~TEXT
      bin/deploy — build this revision and roll it out to K3s.

      Builds HEAD as two linux/amd64 images — syrus (web pod, Dockerfile
      target=app) and syrus-worker-dev (worker pods, target=worker-dev, with
      mise and the multi-language toolchain) — plus one service image per
      container-backed plugin, pushes them to GHCR at :<sha> and :latest, and
      rolls out staging and production.

      Usage:
        bin/deploy                 both clusters (default)
        bin/deploy --staging       staging only
        bin/deploy --production    production only
        bin/deploy --build-only    build and push images, skip the rollout
        bin/deploy --skip-build    assume the images are already pushed
        bin/deploy --dry-run       change nothing; print the command stream
                                   this deploy would run (implies --skip-build)

      Credentials:
        Reads the GHCR token from $GHCR_TOKEN or ~/.config/syrus/ghcr-token
        (chmod 600). It is never printed, and never passed as an argument, so
        it cannot reach the dry run's command stream.

      Timeouts, all accepting seconds or a compound duration such as 1h30m:
        MIGRATION_START_TIMEOUT    scheduling, image pull and boot      (5m)
        MIGRATION_RUN_TIMEOUT      applying migrations                  (30m)
        ROLLOUT_TIMEOUT            one workload's rollout               (15m)
        PREPULL_TIMEOUT            warming the worker image per node    (12m)
        FLUX_SUSPEND_TTL           watchdog auto-resume (default: computed)

      DRY_RUN_STREAM=path captures the dry run's command stream to a file for
      diffing. The previous bash implementation is kept as bin/deploy-legacy
      and takes the same flags.

      After a successful build and push, stale local image tags and unused
      BuildKit cache are pruned. Disable with SYRUS_DOCKER_POST_BUILD_PRUNE=0;
      set the free-space target with SYRUS_DOCKER_POST_BUILD_MIN_FREE_SPACE=20gb.
    TEXT

    class << self
      # Returns a Config, or :help.
      def parse(argv, env: ENV)
        staging = true
        production = true
        skip_build = false
        build_only = false
        dry_run = false

        argv.each do |arg|
          case arg
          when "--staging"     then production = false
          when "--production"  then staging = false
          when "--build-only"  then build_only = true
          when "--skip-build"  then skip_build = true
          when "--dry-run"     then dry_run = true
          when "-h", "--help"  then return :help
          else raise UsageError.new("unknown argument: #{arg}", detail: "see bin/deploy --help")
          end
        end

        Config.new(
          env: env, staging: staging, production: production,
          skip_build: skip_build, build_only: build_only, dry_run: dry_run
        )
      end
    end
  end
end
