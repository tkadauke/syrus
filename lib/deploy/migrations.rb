# frozen_string_literal: true

module Deploy
  # Apply this revision's migrations as an explicit one-shot Job, before any
  # live workload is pointed at the new image.
  #
  # Running them from the new image is the whole point: a currently-running web
  # pod would answer out of the *old* image's db/migrate directory, which does
  # not contain this release's migrations, and would report nothing pending no
  # matter what the database looks like. Only the new image can judge the new
  # schema.
  #
  # The budget is split in two, which is the correction this phase exists for.
  # The previous implementation gave scheduling, image pull, Rails boot and the
  # actual migrations one shared ten-minute clock, then reported every overrun
  # as "did not complete before 10m". Those are different failures with
  # different fixes. A pod that cannot be scheduled or cannot pull its image is
  # broken now and should say so in seconds; applying migrations is
  # legitimately slow, and Syrus has shipped single data migrations that
  # rewrote tens of thousands of rows. Conflating them failed a deploy -- and
  # rolled production back -- over a migration that was running correctly and
  # would have finished.
  #
  # The second correction is that nothing here kills a migration that is
  # running. See the control-stack entry below.
  class Migrations
    WEB_DEPLOYMENT = "deployment/syrus-web"

    # Container states that will never resolve on their own. Waiting out a
    # half-hour budget on one of these only delays the diagnosis.
    TERMINAL_WAITING_REASONS = %w[
      CreateContainerConfigError CreateContainerError ErrImageNeverPull
      ErrImagePull ImagePullBackOff InvalidImageName RunContainerError
    ].freeze

    # Pod spec keys worth carrying from the web deployment so the migration Job
    # lands with the same placement, credentials and volumes as the thing whose
    # database it is migrating.
    COPIED_POD_KEYS = %w[
      affinity automountServiceAccountToken dnsConfig dnsPolicy hostAliases
      imagePullSecrets nodeSelector priorityClassName runtimeClassName
      schedulerName securityContext serviceAccount serviceAccountName
      tolerations topologySpreadConstraints volumes
    ].freeze

    attr_reader :context

    def initialize(context)
      @context = context
    end

    def run!
      unless kubectl.exists?(WEB_DEPLOYMENT)
        raise Failure.new("#{label}: #{WEB_DEPLOYMENT} not found in #{kubectl.namespace}; cannot run migrations before rollout")
      end

      config.migration_attempts.times do |index|
        attempt = index + 1
        return if attempt!(attempt)
      end
    end

    private

    # true when the schema is where this deploy needs it.
    def attempt!(attempt)
      job = job_name(attempt)
      suffix = attempt > 1 ? " (attempt #{attempt}/#{config.migration_attempts})" : ""
      reporter.step("#{label}: applying database migrations with #{config.registry}:#{sha}#{suffix}")

      outcome = apply_and_wait(job)
      if outcome == :complete
        reporter.ok("#{label}: database migrations complete")
        release(job)
        return true
      end

      logs = job_logs(job)
      return handle_lock_contention(job, attempt, logs) if lock_contention?(logs)

      detail = [ kubectl.describe("job", job), logs ].reject(&:empty?).join("\n")
      release(job)
      raise Failure.new("#{label}: database migration job failed", detail: detail)
    end

    # Losing the advisory lock race says nothing about whether the work still
    # needs doing: the process that won it runs the same migrations from the
    # same image. So before retrying -- and before giving up -- ask whether the
    # schema is already where this deploy wants it. A deploy that aborts over
    # migrations another process already applied is a false negative, and that
    # false negative has rolled production back.
    def handle_lock_contention(job, attempt, logs)
      release(job)

      if schema_satisfied?
        reporter.ok("#{label}: database migrations already applied by the process holding the lock")
        return true
      end

      if attempt < config.migration_attempts
        reporter.step("#{label}: a web pod's db-prepare initContainer holds the migration lock; retrying in #{Duration.humanize(config.migration_retry_delay)}")
        clock.sleep(config.migration_retry_delay)
        return false
      end

      raise Failure.new(
        "#{label}: migrations still pending after #{config.migration_attempts} attempts, each blocked by another migration process",
        detail: logs
      )
    end

    def schema_satisfied?
      probe = "syrus-db-check-#{sha}-#{Time.now.to_i}-#{Process.pid}"
      outcome = apply_and_wait(probe, args: [ "runner", PENDING_MIGRATIONS_PROBE ])
      release(probe)
      outcome == :complete
    end

    # Exits non-zero when migrations are pending, so Job completion is the
    # answer. Asked from the new image, for the same reason the migrations
    # themselves are.
    PENDING_MIGRATIONS_PROBE =
      "exit(ActiveRecord::Base.connection_pool.migration_context.needs_migration? ? 1 : 0)"

    def apply_and_wait(job, args: [ "db:prepare" ])
      kubectl.apply(manifest(job, args))
      register_cleanup(job)

      await_start(job)
      await_completion(job)
    end

    # Phase one: the pod exists, was scheduled, pulled its image and started.
    # Short budget, and a state that will never resolve fails immediately
    # rather than burning the clock.
    def await_start(job)
      waiter.until(
        label: "#{label}: migration pod startup",
        timeout: config.migration_start_timeout,
        poll: 3,
        report_every: 20
      ) do
        state = job_state(job)
        next Waiter.converged if state.terminal?
        next Waiter.converged if state.running?

        blocked = state.blocking_reason
        if blocked
          next Waiter.failed("migration pod cannot start (#{blocked})", detail: kubectl.describe("job", job))
        end

        Waiter.pending("#{label}: migration pod #{state.phase_description}")
      end
    end

    # Phase two: applying migrations. Generous, and it reports which migration
    # is running, because a slow migration and a wedged one are the same
    # silence otherwise -- and that indistinguishability is what made a short
    # timeout feel like the only safe setting.
    def await_completion(job)
      verdict = waiter.until(
        label: "#{label}: database migrations",
        timeout: config.migration_run_timeout,
        poll: 10,
        report_every: 30,
        on_timeout: ->(_) { reporter.detail(job_logs(job, tail: 40)) }
      ) do
        state = job_state(job)
        next Waiter.converged("complete") if state.complete?
        next Waiter.converged("failed") if state.failed?

        Waiter.pending("#{label}: migrating#{last_log_line(job)}")
      end

      verdict.note == "failed" ? :failed : :complete
    end

    # The one thing this phase must never do is interrupt a migration.
    #
    # Deleting a Job propagates to its pod, which SIGTERMs Rails in the middle
    # of whatever it is applying -- a half-finished ALTER, a backfill stopped
    # at an arbitrary row. The previous implementation deleted the Job from its
    # exit handler on every failure path, Ctrl-C included, which made
    # interrupting a slow deploy the most destructive thing an operator could
    # do while believing they were being careful.
    #
    # A finished Job is a different matter: it is just clutter, and the TTL
    # would collect it anyway.
    def register_cleanup(job)
      controls.push("migration job/#{job}") do
        state = job_state(job)
        if state.active?
          raise ControlStack::Decline,
            "it is still applying migrations — watch it with " \
            "`kubectl logs -f -n #{kubectl.namespace} job/#{job}`, and deploy again once it finishes"
        end

        kubectl.delete("job", job)
      end
    end

    def release(job)
      kubectl.delete("job", job)
      controls.discharge("migration job/#{job}")
    end

    def job_name(attempt)
      "syrus-db-prepare-#{sha}-#{Time.now.to_i}-#{Process.pid}-#{attempt}"
    end

    def job_logs(job, tail: 200)
      kubectl.logs("job/#{job}", tail: tail).to_s
    end

    def last_log_line(job)
      line = kubectl.logs("job/#{job}", tail: 1).to_s.lines.last.to_s.strip
      line.empty? ? "" : ": #{line}"
    end

    def lock_contention?(logs)
      logs.include?("ConcurrentMigrationError")
    end

    def job_state(job)
      JobState.new(
        document: kubectl.get_json("job", job),
        pods: Array(kubectl.get_json("pods", "-l", "job-name=#{job}")&.fetch("items", nil))
      )
    end

    # The migration Job is derived from the live web deployment rather than
    # written out here, so it inherits whatever that deployment actually needs
    # to reach the database -- its secrets, its service account, its volumes,
    # its placement. A hand-maintained copy drifts, and the way it drifts is
    # that migrations start failing on a cluster whose web pods are fine.
    def manifest(job, args)
      deployment = kubectl.get_json(WEB_DEPLOYMENT)
      raise Failure.new("#{label}: could not read #{WEB_DEPLOYMENT}") if deployment.nil?

      pod_spec = deployment.fetch("spec").fetch("template").fetch("spec")
      labels = { "app" => "syrus", "component" => "db-prepare", "managed-by" => "bin-deploy" }

      {
        "apiVersion" => "batch/v1",
        "kind" => "Job",
        "metadata" => { "name" => job, "labels" => labels },
        "spec" => {
          # Kubernetes must not kill the Job before this script decides to, or
          # the deadline it enforces becomes the real migration timeout and
          # this phase's budget is decoration.
          "activeDeadlineSeconds" => config.migration_deadline_seconds,
          # No retries. A migration that failed needs an operator, not another
          # pod racing the lock.
          "backoffLimit" => 0,
          "ttlSecondsAfterFinished" => 600,
          "template" => {
            "metadata" => { "labels" => labels },
            "spec" => job_pod_spec(pod_spec, args)
          }
        }
      }
    end

    def job_pod_spec(pod_spec, args)
      spec = pod_spec.select { |key, value| COPIED_POD_KEYS.include?(key) && !value.nil? }
      spec["restartPolicy"] = "Never"
      spec["containers"] = [ migration_container(pod_spec, args) ]
      spec
    end

    def migration_container(pod_spec, args)
      containers = Array(pod_spec["initContainers"]) + Array(pod_spec["containers"])
      source =
        containers.find { |container| container["name"] == "db-prepare" } ||
        containers.find { |container| container["name"] == "syrus-web" } ||
        containers.first
      raise Failure.new("#{WEB_DEPLOYMENT} has no container to copy for db prepare") if source.nil?

      source
        .reject { |key, _| %w[args command lifecycle livenessProbe ports readinessProbe startupProbe].include?(key) }
        .merge(
          "name" => "db-prepare",
          "image" => "#{config.registry}:#{sha}",
          "command" => [ "./bin/rails" ],
          "args" => args
        )
    end

    def kubectl = context.kubectl
    def config = context.config
    def reporter = context.reporter
    def waiter = context.waiter
    def controls = context.controls
    def clock = context.clock
    def label = context.label
    def sha = context.sha

    # What one `get job` plus one `get pods` can tell us, which is everything
    # this phase decides on.
    class JobState
      def initialize(document:, pods:)
        @document = document || {}
        @pods = pods || []
      end

      def exists?
        !@document.empty?
      end

      def complete?
        condition?("Complete")
      end

      def failed?
        condition?("Failed")
      end

      def terminal?
        complete? || failed?
      end

      # Still has a pod Kubernetes considers alive. This is the predicate that
      # decides whether cleanup may delete the Job, so it errs toward "yes,
      # something is running": an unreadable Job is treated as active rather
      # than deleted on a guess.
      def active?
        return true unless exists?
        return false if terminal?

        Integer(@document.dig("status", "active") || 0).positive? || running?
      end

      def running?
        pod_phases.include?("Running")
      end

      def phase_description
        return "has not been created yet" if pod_phases.empty?

        reasons = waiting_reasons
        base = pod_phases.uniq.join(", ")
        reasons.empty? ? "is #{base}" : "is #{base} (#{reasons.uniq.join(", ")})"
      end

      def blocking_reason
        stuck = waiting_reasons.find { |reason| TERMINAL_WAITING_REASONS.include?(reason) }
        return stuck if stuck

        "Unschedulable" if unschedulable?
      end

      private

      def condition?(type)
        Array(@document.dig("status", "conditions"))
          .any? { |condition| condition["type"] == type && condition["status"] == "True" }
      end

      def pod_phases
        @pods.map { |pod| pod.dig("status", "phase") }.compact
      end

      def waiting_reasons
        @pods.flat_map do |pod|
          statuses = Array(pod.dig("status", "initContainerStatuses")) + Array(pod.dig("status", "containerStatuses"))
          statuses.filter_map { |status| status.dig("state", "waiting", "reason") }
        end
      end

      def unschedulable?
        @pods.any? do |pod|
          Array(pod.dig("status", "conditions")).any? do |condition|
            condition["type"] == "PodScheduled" && condition["status"] == "False" &&
              condition["reason"] == "Unschedulable"
          end
        end
      end
    end
  end
end
