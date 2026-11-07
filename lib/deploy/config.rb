# frozen_string_literal: true

module Deploy
  # Every knob, resolved and validated before anything touches a cluster.
  #
  # Validation is eager on purpose. A malformed `ROLLOUT_TIMEOUT` used to be
  # discovered at the point of use, which on the unlucky ordering is after Flux
  # is suspended and half the pods have been replaced. Nothing here reads the
  # cluster, so there is no reason not to reject a bad environment while the
  # cluster is still untouched.
  class Config
    DEFAULT_REGISTRY = "ghcr.io/tkadauke/syrus"
    DEFAULT_WORKER_DEV_REGISTRY = "ghcr.io/tkadauke/syrus-worker-dev"
    DEFAULT_PLUGIN_REGISTRY_ROOT = "ghcr.io/tkadauke"

    DEFAULT_ROLLOUT_TARGETS = %w[
      deployment/syrus-web
      deployment/syrus-worker-home
      daemonset/syrus-worker-compute
      deployment/syrus-preview
    ].freeze

    DEFAULT_WORKER_WORKLOADS = %w[
      deployment/syrus-worker-home
      daemonset/syrus-worker-compute
    ].freeze

    Cluster = Struct.new(:label, :kubeconfig, :namespace, keyword_init: true)

    attr_reader :env, :staging, :production, :skip_build, :build_only, :dry_run,
      :dry_run_stream_path

    def initialize(env: ENV, staging: true, production: true, skip_build: false,
                   build_only: false, dry_run: false)
      @env = env
      @staging = staging
      @production = production
      @build_only = build_only
      @dry_run = dry_run
      # A dry run must never need an image: "build nothing" is a far easier
      # property to be certain of than "classify every docker subcommand".
      @skip_build = skip_build || dry_run
      @dry_run_stream_path = env["DRY_RUN_STREAM"].to_s.empty? ? nil : env["DRY_RUN_STREAM"]
      validate!
    end

    # --- images ---------------------------------------------------------

    def registry = fetch("REGISTRY", DEFAULT_REGISTRY)
    def worker_dev_registry = fetch("WORKER_DEV_REGISTRY", DEFAULT_WORKER_DEV_REGISTRY)
    def plugin_registry_root = fetch("SYRUS_PLUGIN_REGISTRY_ROOT", DEFAULT_PLUGIN_REGISTRY_ROOT)
    def ghcr_user = fetch("GHCR_USER", "tkadauke")

    def ghcr_token_file
      fetch("SYRUS_GHCR_TOKEN_FILE", File.join(Dir.home, ".config", "syrus", "ghcr-token"))
    end

    # Off by default, and the comment is the reason: exporting inline cache has
    # to record a compressed digest for every layer, so BuildKit gzips any
    # layer whose compressed form it does not already know. On the build VM
    # that is a ~3.7GB /rails layer, and one deploy spent 4491 of its 4497
    # export seconds in "preparing layers for inline cache" before it had to be
    # killed. What it buys is small anyway: these are plain `docker build` runs,
    # which export no intermediate stage layers, so a registry cache can only
    # serve the final stage -- whose layers are exactly the ones that change on
    # every code deploy. Worth turning on where the local BuildKit cache is cold.
    def inline_cache? = truthy?(fetch("SYRUS_DEPLOY_INLINE_CACHE", "0"))

    # --- clusters -------------------------------------------------------

    def clusters
      list = []
      list << Cluster.new(label: "staging", kubeconfig: staging_kubeconfig, namespace: staging_namespace) if staging
      list << Cluster.new(label: "production", kubeconfig: production_kubeconfig, namespace: production_namespace) if production
      list
    end

    # Staging uses whatever kubectl already points at; production names its
    # file explicitly, which is what keeps two clusters from racing each other
    # through a shared current-context.
    def staging_kubeconfig
      fetch("SYRUS_STAGING_KUBECONFIG", env["KUBECONFIG"].to_s.empty? ? File.join(Dir.home, ".kube", "config") : env["KUBECONFIG"])
    end

    def production_kubeconfig
      fetch("SYRUS_PRODUCTION_KUBECONFIG", File.join(Dir.home, ".kube", "config-production"))
    end

    def staging_namespace = fetch("SYRUS_NAMESPACE_STAGING", "syrus-staging")
    def production_namespace = fetch("SYRUS_NAMESPACE_PRODUCTION", "syrus-production")

    def rollout_targets = words("SYRUS_DEPLOYMENTS", DEFAULT_ROLLOUT_TARGETS)
    def worker_workloads = words("SYRUS_WORKER_WORKLOADS", DEFAULT_WORKER_WORKLOADS)

    # --- rollout --------------------------------------------------------

    # What this has to cover is pod startup, which is dominated by the
    # worker-dev image pull; the pre-pull phase removes most of it. It is not
    # about the worker's 600s terminationGracePeriodSeconds, which is not
    # load-bearing: SolidQueue's shutdown_timeout is 5s and Syrus does not
    # override it, and measured termination during a production rollout was
    # 6-13 seconds. In-flight Runs do not survive a deploy; the stale-run
    # reaper and the auto-retry path are what recover them.
    def rollout_timeout = duration("ROLLOUT_TIMEOUT", "15m")
    def rollout_poll_interval = duration("ROLLOUT_POLL_INTERVAL", "5s")
    def rollout_report_interval = duration("ROLLOUT_STALL_DIAGNOSE_INTERVAL", "90s")
    def rollout_verbose? = truthy?(fetch("ROLLOUT_VERBOSE_DIAGNOSTICS", "false"))

    # --- pre-pull -------------------------------------------------------

    def prepull? = !truthy_off?(fetch("PREPULL", "1"))

    # One pull's wall clock plus contention for the uplink, not one per node:
    # every compute node fetches the image at the same time.
    def prepull_timeout = duration("PREPULL_TIMEOUT", "12m")
    def prepull_daemonset = fetch("SYRUS_PREPULL_DAEMONSET", "syrus-image-prepull")

    # --- migrations -----------------------------------------------------

    # Scheduling, pulling the image and booting Rails. Short on purpose: a
    # migration pod that cannot be scheduled or cannot pull is a failure to
    # report now, not something to sit out for half an hour.
    def migration_start_timeout = duration("MIGRATION_START_TIMEOUT", "5m")

    # Actually applying migrations, which is legitimately long. Syrus has
    # shipped single data migrations that rewrote tens of thousands of rows,
    # and the old implementation's one shared ten-minute budget failed the
    # deploy over one of them -- then rolled production back -- while the
    # migration itself was running correctly. DB_PREPARE_TIMEOUT is honoured as
    # the alias operators already know, because raising it is exactly how that
    # incident was worked around by hand.
    def migration_run_timeout
      legacy = env["DB_PREPARE_TIMEOUT"]
      return Duration.seconds(legacy, name: "DB_PREPARE_TIMEOUT") unless legacy.to_s.empty?

      duration("MIGRATION_RUN_TIMEOUT", "30m")
    end

    # Kubernetes must not kill the Job before this script decides to. The slack
    # covers the gap between the Job starting and the first poll observing it.
    def migration_deadline_seconds
      migration_start_timeout + migration_run_timeout + 120
    end

    # Only ActiveRecord::ConcurrentMigrationError is retried. Rails takes a
    # MySQL advisory lock around migrations, and the web pod's own db-prepare
    # initContainer runs on every replica at every boot -- so a Flux reconcile,
    # an eviction or simply both replicas booting together makes the loser die
    # with that error. It means "someone else is already doing exactly this
    # work", which is transient by construction. A real migration failure still
    # fails the deploy on the first attempt.
    def migration_attempts = integer("DB_PREPARE_ATTEMPTS", 4)
    def migration_retry_delay = duration("DB_PREPARE_RETRY_DELAY", "20s")

    # --- flux -----------------------------------------------------------

    def flux_namespace = fetch("FLUX_NAMESPACE", "flux-system")
    def flux_kustomization = fetch("FLUX_KUSTOMIZATION", "apps")
    def flux_suspend_slack = duration("FLUX_SUSPEND_SLACK", "5m")
    def flux_watchdog_image = fetch("FLUX_WATCHDOG_IMAGE", "alpine/k8s:1.31.13")
    def flux_image_field_manager = fetch("FLUX_IMAGE_FIELD_MANAGER", "flux-client-side-apply")

    def flux_suspend_ttl_override
      value = env["FLUX_SUSPEND_TTL"]
      return nil if value.to_s.empty?

      Integer(value, 10)
    rescue ArgumentError, TypeError
      raise UsageError.new("FLUX_SUSPEND_TTL must be an integer number of seconds")
    end

    # Every bounded phase that runs while Flux is suspended, plus one rollout
    # timeout for the unbounded setup and verification work and for scheduling
    # overhead. Computed after the cluster's real targets are discovered, so
    # optional and plugin workloads extend the watchdog instead of quietly
    # eating its safety margin.
    def flux_suspend_budget_seconds(rollout_target_count)
      (prepull? ? prepull_timeout : 0) +
        migration_start_timeout + migration_run_timeout +
        (rollout_target_count + 1) * rollout_timeout +
        flux_suspend_slack
    end

    # --- other cluster-side controls ------------------------------------

    def mise_cache_host_path = fetch("MISE_CACHE_HOST_PATH", "/data/syrus-mise-cache")
    def mysql_backup_cronjob = fetch("MYSQL_BACKUP_CRONJOB", "syrus-mysql-backup")
    def mysql_backup_drain_timeout = duration("MYSQL_BACKUP_DRAIN_SECONDS", "30s")

    private

    def fetch(key, default)
      value = env[key]
      value.to_s.empty? ? default : value
    end

    def words(key, default)
      value = env[key]
      value.to_s.empty? ? default : value.split
    end

    def duration(key, default)
      Duration.seconds(fetch(key, default), name: key)
    end

    def integer(key, default)
      Integer(fetch(key, default.to_s), 10)
    rescue ArgumentError, TypeError
      raise UsageError.new("#{key} must be an integer")
    end

    def truthy?(value)
      %w[1 true yes on].include?(value.to_s.strip.downcase)
    end

    def truthy_off?(value)
      %w[0 false no off].include?(value.to_s.strip.downcase)
    end

    # Touch every duration and integer once, here, so a malformed one is
    # rejected now rather than mid-rollout.
    def validate!
      rollout_timeout
      rollout_poll_interval
      rollout_report_interval
      prepull_timeout
      migration_start_timeout
      migration_run_timeout
      migration_attempts
      migration_retry_delay
      flux_suspend_slack
      flux_suspend_ttl_override
      mysql_backup_drain_timeout
    rescue Duration::Invalid => e
      raise UsageError.new(e.message)
    end
  end
end
