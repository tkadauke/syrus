class RunJob < ApplicationJob
  # Dedicated `runs` queue with its own SQ worker — see
  # config/queue.yml. RunJobs are minutes-long agent invocations;
  # putting them on a shared background queue starves control-plane
  # jobs, app events, and recurring reapers/pollers, which makes the
  # UI feel frozen during heavy load and (in the worst case)
  # leaves zombie Runs stuck "running" because ReapStaleRunsJob
  # can't get a thread. Splitting queues keeps short jobs fast.
  queue_as :runs

  # One mutable-workspace Run at a time per Job. Per-Job (not per-repo) is the
  # right granularity for Steps that share the Workflow workspace at
  # $SYRUS_DATA_ROOT/workflows/<workflow_id>/, because two concurrent Runs on
  # the same Job could interleave on disk. Distributed immutable-source Steps
  # are different: each projected grader gets its own detached checkout and
  # RunHostAdmission bounds per-worker pressure, so their Solid Queue key is
  # per Run under the distributed gate.
  limits_concurrency to: 1, key: ->(run_id) {
    ::RunJob.concurrency_key_for(run_id)
  }

  discard_on ActiveRecord::RecordNotFound
  # A pool timeout is transient: the Run is still queued, so deliver the job
  # again rather than strand it until the reconciler notices.
  retry_on ActiveRecord::ConnectionTimeoutError, wait: 15.seconds, attempts: 20

  # Count deferrals instead of wall-clock age because a slow or paused queue
  # should not burn a placement pin while no worker is actively refusing it.
  # RunHostAdmission retries every 30 seconds, so 40 refusals gives a healthy
  # pinned host about twenty minutes to recover before Syrus pays the re-clone
  # cost and lets the Run land on another eligible worker.
  PINNED_HOST_ADMISSION_DEFERRAL_BUDGET = 40
  LIFECYCLE_LOCK_RETRY_ERRORS = [
    ActiveRecord::Deadlocked,
    ActiveRecord::LockWaitTimeout
  ].freeze
  LIFECYCLE_LOCK_RETRY_ATTEMPTS = 3

  Syrus::Metrics.declare do
    counter :run_lifecycle_lock_retries_total, tags: %i[kind queue outcome], cluster: true,
            comment: "Run lifecycle persistence lock conflicts, including recovered and exhausted retries"
  end

  # Test seam — let specs swap in a fake runner without exec'ing claude.
  class << self
    attr_accessor :agent_runner

    def concurrency_key_for(run_id)
      run = ::Run.includes(step: { workflow: { job: :repository } }).find_by(id: run_id)
      return "run:#{run_id}" unless run
      return "run:#{run.id}" if distributed_parallel_run?(run)

      "job:#{run.job_id}"
    end

    def distributed_parallel_run?(run)
      run&.distributed_parallel_run?
    end
  end

  # Every Run in the new model belongs to a Step (via `runs.step_id`),
  # so RunJob's job is to:
  #
  #   1. Pre-flight: skip already-terminal Runs, abort if the
  #      parent Workflow is already terminal (something else reaped
  #      or cancelled this chain).
  #   2. Re-entrancy guard: a Run found in `running` state on entry
  #      means the prior worker died mid-perform — fail it with
  #      `worker_died` so the operator can use Retry.
  #   3. Bring Workflow + Step + Run all to `running`.
  #   4. Dispatch to the per-kind handler in Steps::*. Handlers do
  #      not manage state — they just do the work or raise.
  #   5. On success: succeed Run + Step. Step.after_update_commit
  #      fires StepDispatcher.advance_from synchronously, which
  #      creates the next Step's Run inline (Run#enqueue_run_job
  #      sees Thread.current[:syrus_in_run_job] and skips the
  #      perform_later — the loop below picks the new Run up
  #      directly so the worker drives the entire Workflow chain
  #      depth-first instead of bouncing through SQ between steps).
  #   6. On failure: capture a diagnostic and fail the Run. Run's
  #      after_update_commit cascades into StepDispatcher.fail_from,
  #      which either continues a grade loop or hard-fails the
  #      Workflow.
  # When the operator console pauses runs, fresh perform-attempts
  # re-enqueue themselves with a delay rather than starting work.
  # The Run stays in `queued` (or whatever state it was in); the
  # next attempt rechecks. When unpaused, work proceeds. Cost
  # while paused: 1 re-enqueue per Run per RUNS_PAUSED_RETRY_DELAY,
  # which is fine for a kill-switch state that's typically minutes,
  # not days.
  RUNS_PAUSED_RETRY_DELAY = 30.seconds
  # A worker that does not provide a step's kind (its plugin is not loaded
  # here, during a fleet rollout or for a role-limited installation) hands the
  # Run back for one that does, at most this many times, before the Step fails
  # as unknown (formal/SyrusModel/UnknownKindHandback.lean).
  UNKNOWN_KIND_HANDBACK_DELAY = 30.seconds
  UNKNOWN_KIND_HANDBACK_LIMIT = 20
  AGENT_CONCURRENCY_RETRY_DELAY = 15.seconds
  STEP_DEPENDENCY_RETRY_DELAY = 15.seconds
  MISSING_WORKSPACE_RETRY_DELAY = 1.minute
  # A workspace in these states existed; its absence means it was lost.
  WORKSPACE_EXPECTED_LIFECYCLE_STATES = %w[created reconstructed storage_lost].freeze
  WORK_UNIT_LOCK_RETRY_DELAY = 15.seconds
  MACOS_WORKER_DRAIN_RETRY_DELAY = 30.seconds
  MACOS_VERSION_SKEW_RETRY_DELAY = 1.minute
  FRESH_RUNNING_REENTRY_THRESHOLD = Run::STALE_HEARTBEAT_THRESHOLD

  def perform(run_id)
    # Captured before any early return: the ensure below hands back only Runs
    # this perform held, and restores an enclosing perform's list untouched.
    prior_held_run_ids = Thread.current[::Run::INLINE_HELD_RUN_IDS]
    Thread.current[::Run::INLINE_HELD_RUN_IDS] = []
    Thread.current[:syrus_current_queue_role] = queue_name.to_s

    if AppSetting.runs_paused?
      Rails.logger.info("[RunJob] runs paused — deferring Run ##{run_id} by #{RUNS_PAUSED_RETRY_DELAY}")
      defer_run(run_id, RUNS_PAUSED_RETRY_DELAY)
      return
    end

    return if defer_for_agent_concurrency?(run_id)
    return if defer_for_actor_share?(run_id)

    @run = ::Run.find(run_id)
    Thread.current[:syrus_current_run] = @run
    Thread.current[:syrus_in_run_job] = true
    return if @run.terminal?

    @step = @run.step
    @workflow = @step&.workflow
    @job = @run.job
    return if defer_for_macos_worker_drain?
    return if defer_for_macos_version_skew?
    return if hand_back_incapable_run?
    return if hand_back_unknown_step_kind?
    return fail_unknown_step_kind! unless step_kind_provided_here?(@step)

    @shutdown_requested = false
    prior_trap = Signal.trap("TERM") do
      @shutdown_requested = true
      prior_trap.call if prior_trap.respond_to?(:call)
    end

    loop do
      break if @shutdown_requested
      break if defer_for_macos_worker_drain?
      perform_step
      next_run = next_inline_run
      # An inline successor this process cannot run goes back to the queue
      # through the ordinary hand-back, for a worker that provides its kind.
      next_run = nil if next_run && !step_kind_provided_here?(next_run.step)
      release_inline_held_runs!(except: @shutdown_requested ? nil : next_run)
      break unless next_run
      if @shutdown_requested
        Rails.logger.info("[RunJob] SIGTERM — yielding at step boundary for Run ##{@run.id}, successor Run ##{next_run.id} handed back to the queue")
        break
      end
      @run = next_run
      @step = @run.step
      @handler = nil
      Thread.current[:syrus_current_run] = @run
    end
  rescue StandardError => e
    # Let ApplicationJob's discard_on handler consume stale queue entries.
    # A missing initial Run raises before @run is assigned; routing it through
    # the step-failure path would try to append a JobLog for nil and mask the
    # intentionally discardable exception with NoMethodError. RecordNotFound
    # raised later by a step still belongs to that Run's normal failure path.
    raise if e.is_a?(ActiveRecord::RecordNotFound) && !@run
    # Anything else raised before the Run loaded (a pool timeout in the
    # pause or concurrency checks, say) has no Run to fail or log against.
    # Raise it as it is: handle_failure would mask it with a NoMethodError
    # on the nil Run, and retry_on below redelivers the transient ones.
    raise unless @run

    if PostImplementationReviewFailure.optional_step?(@step)
      log("WARNING: optional post-implementation review failed: #{e.class}: #{e.message}", kind: "system")
      PostImplementationReviewFailure.record!(run: @run, exception: e, workspace: handler_workspace)
      return
    end

    handle_failure(e)
    return if @run&.cancelled?

    if workflow_controlled_failure?
      continue_inline_after_controlled_failure
    else
      raise
    end
  ensure
    Signal.trap("TERM", prior_trap) if prior_trap
    release_inline_held_runs!(on_exit: true)
    Thread.current[::Run::INLINE_HELD_RUN_IDS] = prior_held_run_ids
    Thread.current[:syrus_current_run] = nil
    Thread.current[:syrus_in_run_job] = nil
    Thread.current[:syrus_current_queue_role] = nil
  end

  private

  # Re-enqueue this Run after a delay, preserving its Job's SolidQueue priority
  # and storage affinity. A mutable workflow may start on the generic `runs` or
  # `merges` queue and only later record the worker data root that owns its
  # workspace. Once that storage key exists, deferred retries must move onto the
  # corresponding resume queue; otherwise host admission can bounce a later
  # agentic step to a different pod that has only stale local debris for the same
  # workflow id.
  # Used by the runs-paused and agent-concurrency gates.
  def defer_run(run_id, delay)
    run = ::Run.find_by(id: run_id)
    sq_num = run&.solid_queue_priority || ::Job::PRIORITY_TO_SQ["medium"]
    queue = run ? RunQueueResolver.resolve(run: run).queue_name : queue_name
    self.class.set(queue: queue, wait: delay, priority: sq_num).perform_later(run_id)
  end

  def dispatch_run(run_id, queue:, delay: nil)
    run = ::Run.find_by(id: run_id)
    return unless run && !run.terminal?

    options = { queue: queue, priority: run.solid_queue_priority }
    options[:wait] = delay if delay
    self.class.set(**options).perform_later(run_id)
  end

  # Global, cluster-wide cap on concurrent agent Runs (the `:runs` queue),
  # admin-configured via AppSetting.max_concurrent_agent_runs. SolidQueue's
  # per-job concurrency key (job:<id>) is already used for per-Job
  # serialization, so this is a best-effort DB-counted gate rather than a
  # second SolidQueue semaphore: if the cap is already met, this Run bounces
  # back to the queue with a short delay. DB-counted so it holds across worker
  # pods (per-pod JOB_CONCURRENCY only bounds a single pod). Best-effort — a
  # couple extra may slip through under contention; it's a cost/rate ceiling,
  # not a hard lock. 0 = unlimited. Main-branch graders and repair jobs also
  # run on `:runs`, but are exempt so user Job bursts cannot make the health
  # signal stale or keep main broken while the landing queue is paused.
  # Landing/merge Runs are not capped (different queues, isolated pools).
  def defer_for_agent_concurrency?(run_id)
    return false unless AdmissionControl.enabled?

    limit = AppSetting.max_concurrent_agent_runs
    return false if limit <= 0

    run = ::Run.find_by(id: run_id)
    return false unless run && !run.terminal? && run.agentic_step?
    return false if work_definition_for_run(run).agent_concurrency_exempt?

    active = ::Run.running_agent_runs.where.not(id: run_id).count
    return false if active < limit

    Rails.logger.info("[RunJob] agent concurrency #{active}/#{limit} reached — deferring Run ##{run_id} by #{AGENT_CONCURRENCY_RETRY_DELAY.inspect}")
    defer_run(run_id, AGENT_CONCURRENCY_RETRY_DELAY)
    true
  end

  # workflow-engine-v3 C1's fairness rung. The global cap alone lets one user's
  # large Epic occupy every slot, because admission keys have no actor
  # dimension.
  #
  # This always defers and never fails, which the plan is emphatic about: a
  # starvation guard that fails work converts a queueing problem into an
  # attention problem. The work keeps its place and runs when the contention
  # clears.
  def defer_for_actor_share?(run_id)
    run = ::Run.find_by(id: run_id)
    return false unless run && !run.terminal? && run.agentic_step?
    return false if work_definition_for_run(run).agent_concurrency_exempt?

    return false unless AdmissionControl.enabled?

    share = Admission::FairShare.for(user: run.user, excluding_run_id: run_id)
    return false unless share.over_share?

    Rails.logger.info(
      "[RunJob] actor_fair_share for user ##{run.user_id} " \
        "(#{share.to_h.inspect}) — deferring Run ##{run_id} by #{AGENT_CONCURRENCY_RETRY_DELAY.inspect}"
    )
    defer_run(run_id, AGENT_CONCURRENCY_RETRY_DELAY)
    true
  end

  def defer_for_host_admission?
    admission = RunHostAdmission.call(run: @run, queue_name: queue_name)
    return false if admission.admit?

    routing = DistributedRunAdmissionRouter.call(run: @run, admission: admission)
    admission_artifact = record_host_admission_deferral!(admission, routing: routing)
    if routing.reroute?
      Rails.logger.info(
        "[RunJob] host admission #{admission.reason} on #{admission.details['hostname']} - " \
          "rerouting Run ##{@run.id} to #{routing.queue_name}"
      )
      dispatch_run(@run.id, queue: routing.queue_name)
      return true
    end
    if pinned_host_admission_budget_exhausted?(admission_artifact)
      pruned = SolidQueueRunJobPruner.delete_pending_for_run!(@run.id)
      clear_workflow_storage_affinity!
      Rails.logger.warn(
        "[RunJob] host admission #{admission.reason} exhausted pinned deferral budget on " \
          "#{admission.details['hostname']} - pruned #{pruned} pending queue rows and rerouting Run ##{@run.id} to the base queue"
      )
    end
    Rails.logger.info(
      "[RunJob] host admission #{admission.reason} on #{admission.details['hostname']} - " \
        "deferring Run ##{@run.id} by #{admission.delay.inspect}"
    )
    defer_run(@run.id, routing.delay)
    true
  end

  # A worker claims from shared queues by queue name alone, and a Run whose
  # placement merely defaults to Linux skips the live capability check -- so
  # the macOS worker, which consumes the shared compute queue, ran every Linux
  # grader of a macOS-home workflow's landing while Linux workers sat idle.
  # A worker runs only what it satisfies; anything else goes back to the queue
  # the resolver picks, for a worker that does.
  CAPABILITY_HANDBACK_DELAY = 5.seconds

  def hand_back_incapable_run?
    return false unless @run&.queued? && compute_run?
    return false if RunQueueResolver.locally_satisfied?(run: @run)

    Rails.logger.info("[RunJob] this worker does not satisfy Run ##{@run.id}'s placement requirements - handing it back")
    # No live worker satisfies it either (the last capable one failed a smoke
    # check after the Run was enqueued): block it with the resolver's reason
    # and a recheck, as the first enqueue does. Re-enqueueing it onto the same
    # queue let this worker claim and hand it back every few seconds with no
    # reason recorded (F150).
    decision = RunQueueResolver.resolve(run: @run)
    if decision.blocked?
      @run.send(:block_for_missing_capable_worker!, decision)
    else
      defer_run(@run.id, CAPABILITY_HANDBACK_DELAY)
    end
    true
  rescue StandardError => e
    Rails.logger.warn("[RunJob] capability check failed for Run ##{@run&.id}: #{e.class}: #{e.message}")
    false
  end

  def hand_back_unknown_step_kind?
    return false unless @run&.queued? && @step
    return false if step_kind_provided_here?(@step)

    handbacks = @step.details.to_h["unknown_kind_handbacks"].to_i
    return false if handbacks >= UNKNOWN_KIND_HANDBACK_LIMIT

    @step.update!(details: @step.details.to_h.merge("unknown_kind_handbacks" => handbacks + 1))
    Rails.logger.info(
      "[RunJob] step kind #{@step.kind.inspect} is not provided on this worker - " \
        "handing Run ##{@run.id} back (#{handbacks + 1}/#{UNKNOWN_KIND_HANDBACK_LIMIT})"
    )
    defer_run(@run.id, UNKNOWN_KIND_HANDBACK_DELAY)
    true
  end

  def step_kind_provided_here?(step)
    Step::Kind.values.include?(step.kind.to_s)
  end

  def fail_unknown_step_kind!
    plugin = plugin_owning_step_kind(@step.kind) || "unavailable_plugin"
    error = ArgumentError.new("plugin step handler is unavailable for step kind=#{@step.kind.inspect}")
    Syrus::PluginInvocation.runtime_health.record_failure(
      plugin:, extension_point: :workflow_kinds, operation: :dispatch, exception: error,
      threshold: 1, window: 1.minute, cooldown: 1.minute, circuit: false,
      provider: @step.kind
    )
    @step.update!(details: @step.details.to_h.merge(
      "plugin_health_finding" => {
        "plugin" => plugin,
        "code" => "step_handler_unavailable",
        "step_kind" => @step.kind,
        "message" => error.message
      }
    ))
    handle_failure(error)
    log("plugin-owned step #{@step.kind} failed because its handler is unavailable", kind: "system")
    true
  end

  def plugin_owning_step_kind(kind)
    Syrus::PluginRegistry.all_plugins.find do |manifest|
      Array(manifest.provides[:workflow_kinds]).any? do |provider|
        provider = provider.safe_constantize if provider.is_a?(String)
        next false unless provider&.respond_to?(:step_kinds)

        Array(provider.step_kinds).any? { |attrs| attrs.to_h.with_indifferent_access[:kind].to_s == kind.to_s }
      rescue StandardError
        false
      end
    end&.name
  end

  def defer_for_macos_worker_drain?
    return false unless @run&.queued?
    return false unless compute_run?
    return false unless local_macos_worker?

    worker_storage_key = WorkerStorageIdentity.queue_key
    hostname = SyrusVersion.hostname
    drain = MacosWorkerDrain
      .for_identity(worker_storage_key: worker_storage_key, hostname: hostname)
      .blocking_admission
      .first
    return false unless drain

    record_macos_worker_drain_deferral!(drain, worker_storage_key: worker_storage_key, hostname: hostname)
    Rails.logger.info(
      "[RunJob] macOS worker #{hostname}/#{worker_storage_key} is #{drain.state} - " \
        "deferring Run ##{@run.id} by #{MACOS_WORKER_DRAIN_RETRY_DELAY.inspect}"
    )
    defer_run(@run.id, MACOS_WORKER_DRAIN_RETRY_DELAY)
    true
  end

  # Every deploy activates a macOS worker release for the revision it rolled
  # out, after that revision's migrations ran. A Mac worker still on another
  # revision would run its code against a schema it was not built for, so it
  # hands the Run back until the updater has installed the active release and
  # the worker has restarted on it.
  def defer_for_macos_version_skew?
    return false unless @run&.queued?
    return false unless compute_run?
    return false unless local_macos_worker?

    desired = ::MacosWorkerRelease.desired_git_sha
    running = SyrusVersion.current
    return false if desired.blank? || running.blank? || running == "dev"
    return false if ::MacosWorkerRelease.same_revision?(running, desired)

    chunk = "macOS worker runs #{running}, but the active release is #{desired}; waiting for the update before #{@step.kind}"
    JobLog.append!(run: @run, kind: "system", chunk: chunk) unless admission_deferral_log_exists?(chunk)
    Rails.logger.info("[RunJob] #{chunk} - deferring Run ##{@run.id} by #{MACOS_VERSION_SKEW_RETRY_DELAY.inspect}")
    defer_run(@run.id, MACOS_VERSION_SKEW_RETRY_DELAY)
    true
  rescue StandardError => e
    Rails.logger.warn("[RunJob] macOS version skew check failed for Run ##{@run&.id}: #{e.class}: #{e.message}")
    false
  end

  def record_macos_worker_drain_deferral!(drain, worker_storage_key:, hostname:)
    @workflow.update!(
      artifacts: (@workflow.artifacts || {}).merge(
        "macos_worker_drain_admission" => {
          "action" => "defer",
          "reason" => "macos_worker_#{drain.state}",
          "worker_storage_key" => worker_storage_key,
          "hostname" => hostname,
          "drain_id" => drain.id,
          "desired_git_sha" => drain.desired_git_sha,
          "deferred_at" => Time.current.iso8601,
          "retry_at" => (Time.current + MACOS_WORKER_DRAIN_RETRY_DELAY).iso8601
        }.compact
      )
    )
    chunk = "macOS worker drain deferred before #{@step.kind}: #{drain.state}"
    JobLog.append!(run: @run, kind: "system", chunk: chunk) unless admission_deferral_log_exists?(chunk)
  rescue StandardError => e
    Rails.logger.warn("[RunJob] failed to record macOS worker drain deferral for Run ##{@run.id}: #{e.class}: #{e.message}")
  end

  def compute_run?
    Workflows.for(trigger_kind: @run.trigger_kind).queue_name.to_s.in?(%w[runs merges])
  rescue ArgumentError
    false
  end

  def local_macos_worker?
    Array(WorkerCapabilities.current.fetch(:capabilities).fetch("os", [])).map(&:to_s).include?("macos")
  end

  def record_host_admission_deferral!(admission, routing: nil)
    prior = @workflow.artifact("run_host_admission").to_h
    # Per-Run counts: the artifact is per Workflow, and sibling Runs (parallel
    # grader shards deferring each other) would otherwise reset each other's
    # count on every round, so the budget that ends this loop never ran out.
    counts = prior["deferral_counts"].is_a?(Hash) ? prior["deferral_counts"].dup : {}
    counts[prior["run_id"].to_s] ||= prior["deferral_count"].to_i if prior["run_id"].present?
    count = counts[@run.id.to_s].to_i + 1
    counts[@run.id.to_s] = count
    first_deferred_at = count == 1 ? Time.current.iso8601 : prior["first_deferred_at"].presence || Time.current.iso8601
    payload = admission.details.merge(routing&.details.to_h || {}).merge(
      "action" => routing&.action || admission.action,
      "reason" => admission.reason,
      "run_id" => @run.id,
      "step_id" => @step.id,
      "workflow_id" => @workflow.id,
      "deferred_at" => Time.current.iso8601,
      "first_deferred_at" => first_deferred_at,
      "retry_at" => routing&.reroute? ? nil : (Time.current + (routing&.delay || admission.delay)).iso8601,
      "routed_at" => routing&.reroute? ? Time.current.iso8601 : nil,
      "routed_queue" => routing&.queue_name,
      "deferral_count" => count,
      "deferral_counts" => counts,
      "deferral_budget" => PINNED_HOST_ADMISSION_DEFERRAL_BUDGET
    )
    @workflow.update!(
      artifacts: (@workflow.artifacts || {}).merge(
        "run_host_admission" => payload
      )
    )
    JobLog.append!(
      run: @run,
      kind: "system",
      chunk: "compute host admission deferred before #{@step.kind}: #{admission.reason}"
    ) unless admission_deferral_log_exists?("compute host admission deferred before #{@step.kind}: #{admission.reason}")
    record_memory_binding_guidance!(admission)
    payload
  rescue StandardError => e
    Rails.logger.warn("[RunJob] failed to record host admission deferral for Run ##{@run.id}: #{e.class}: #{e.message}")
    admission.details.merge("reason" => admission.reason, "run_id" => @run.id, "deferral_count" => 1)
  end

  def record_memory_binding_guidance!(admission)
    binding_terms = Array(admission.details["resource_guard_binding_terms"])
    return unless binding_terms.intersect?(%w[memory_reservation measured_memory])

    chunk = if admission.details["candidate_memory_evidence_source"] == "deterministic_compute_fallback"
      "host memory admission is binding; collect command resource samples to replace the bounded deterministic fallback or increase the Docker memory setting"
    else
      "host memory admission is binding; tune SYRUS_WORKER_CPU_LIMIT to change capacity-unit reservations or increase the Docker memory setting"
    end
    JobLog.append!(run: @run, kind: "system", chunk: chunk) unless admission_deferral_log_exists?(chunk)
  end

  def pinned_host_admission_budget_exhausted?(artifact)
    return false unless @workflow.worker_storage_key.present?
    return false unless artifact.to_h["run_id"].to_i == @run.id

    artifact.to_h["deferral_count"].to_i >= PINNED_HOST_ADMISSION_DEFERRAL_BUDGET
  end

  def clear_workflow_storage_affinity!
    WorkflowWorkspaceLifecycle.clear_routing_affinity!(
      @workflow,
      actor: "run_job",
      reason: "pinned host admission deferral budget exhausted"
    )
    @workflow.reload
    @step.association(:workflow).reset
    @run.association(:step).reset
  end

  def admission_deferral_log_exists?(chunk)
    JobLog.where(run: @run, kind: "system", chunk: chunk).exists?
  end

  def complete_pre_admission_skip?
    result = RunPreAdmissionSkip.call(run: @run)
    return false unless result.skip?

    return false unless acquire_run_execution!

    log(result.message, kind: "system") if result.message.present?
    result.artifacts.each { |key, value| @workflow.set_artifact!(key, value) }
    @step.update!(details: @step.details.to_h.merge("skipped" => true, "skip_reason" => result.reason))

    @run.reload
    @step.reload
    @workflow.reload
    return true if @run.terminal? || @step.terminal? || @workflow.terminal?

    commit_run_and_step_success!
    log("step #{@step.kind} done (#{@workflow.slug})")
    true
  end

  def perform_step
    if @workflow.nil? || @step.nil?
      raise "Run ##{@run.id} has no Step / Workflow — backfill must run before legacy Runs can execute"
    end

    unless execution_owner_consistent?
      log("execution owner mismatch; refusing to run")
      fail_run_without_validation!("execution_owner_mismatch")
      if @step.may_fail?
        @step.fail!
        @step.save!
      end
      return
    end

    if @workflow.terminal?
      log("#{@workflow.slug} already terminal (#{@workflow.state}); abandoning run")
      @run.cancel! if @run.may_cancel?
      @run.save!
      return
    end

    if StepDispatcher.job_closed_for_execution?(@workflow)
      log("#{@job.slug} is closed; cancelling #{@workflow.slug} instead of running #{@step.kind}")
      StepDispatcher.cancel_unstartable_closed_job_workflow!(@workflow)
      @run.reload
      if @run.may_cancel?
        @run.cancel!
        @run.save!
      end
      return
    end

    return if cancel_ineligible_retry_workflow!

    if @step.terminal?
      log("step ##{@step.id} already terminal (#{@step.state}); skipping obsolete run")
      @run.skip! if @run.may_skip?
      @run.save!
      return
    end

    unless Workflows::ImmutableReviewHeadBarrier.satisfied_for?(@step)
      log("required review barrier unresolved for current implementation HEAD; cancelling unsafe queued Run", kind: "system")
      Workflows::ImmutableReviewHeadBarrier.cancel_run_without_cascade!(@run)
      @workflow.set_artifact!("review_head_barrier_block", {
        "code" => "required_review_head_unresolved",
        "step_id" => @step.id,
        "run_id" => @run.id,
        "recorded_at" => Time.current.iso8601
      })
      return
    end

    authorization_continuation = pending_authorization_continuation?
    return if !authorization_continuation && handle_running_reentry
    return if defer_until_step_dependencies_settle
    return if defer_for_missing_workspace?

    if workflow_starting? && (merged_pr = merged_pull_request)
      succeed_workflow_for_merged_pull_request!(merged_pr)
      return
    end

    return if complete_pre_admission_skip?

    return if defer_for_host_admission?

    unless authorization_continuation || acquire_run_execution!
      return
    end

    record_mutable_workspace_identity!

    target = @job.cron? ? "scheduled task ##{@job.origin_id}" : "#{@job.repository.slug}##{@job.issue_number}"
    log("starting #{@workflow.trigger_kind} run #{@run.id} step #{@step.kind} for #{target}")

    @handler = Steps.handler_for(@step.kind).new(@run)
    return if authorization_continuation && !claim_authorization_continuation!

    begin
      @handler.call
    rescue Steps::Base::AuthorizationCheckpointReached
      log("step #{@step.kind} released its provider while waiting for permission", kind: "system")
      return
    rescue Steps::Base::AwaitingOperatorAnswer
      park_for_operator_answer!
      return
    rescue Steps::Base::RunEndedExternally => e
      log("step #{@step.kind} stopped: #{e.message}", kind: "system")
      return
    rescue Steps::Base::CannotProceed => e
      if PostImplementationReviewFailure.optional_step?(@step)
        log("WARNING: optional post-implementation review could not proceed: #{e.reason}", kind: "system")
        PostImplementationReviewFailure.record!(run: @run, exception: e, workspace: handler_workspace)
        return
      end
      if @workflow.artifact("cannot_proceed").to_h["disposition"] == "failed"
        fail_after_transient_cannot_proceed!(e.reason)
      else
        block_after_cannot_proceed!(e.reason)
      end
      return
    rescue Steps::Base::StepSkipped => e
      skip_after_step_skipped!(e)
      return
    end

    # A reaper, operator stop, or another state propagator can make
    # this Run/Step/Workflow terminal while the handler is still
    # executing. Reload before deciding success so we don't overwrite
    # that terminal state from stale in-memory records.
    @run.reload
    @step.reload
    @workflow.reload

    if @run.terminal? || @step.terminal? || @workflow.terminal?
      handle_terminal_after_successful_handler
      return
    end

    record_successful_step!
    log("step #{@step.kind} done (#{@workflow.slug})")
  end

  # Queue pickup is not workspace ownership. Commit affinity only after host
  # admission and the execution lease succeed, immediately before a mutable
  # handler can create or change the workflow workspace. Distributed runs use
  # immutable per-step checkouts and must not steal the mutable workspace's
  # existing identity.
  def record_mutable_workspace_identity!
    @workflow.record_worker_identity! unless @run.distributed_parallel_run?
  end

  # Graders and their collectors read the workflow workspace without setting
  # it up. After a worker restart loses the workspace, a retried collector
  # crashed on the missing directory within a second, failing the reopened
  # Workflow before the reconciler could reconstruct it, so every retry
  # looped. Hold the Run queued instead: the Workflow is running with a live
  # Run, which is exactly what recover_missing_workspace repairs and resumes.
  def defer_for_missing_workspace?
    return false unless @step.kind.in?(WorkflowWorkspaceRecovery::REPLAY_SAFE_KINDS)
    return false if WorkflowWorkspaceRecovery::WORKSPACE_FREE_PLACEMENTS.include?(@step.placement_policy)
    return false unless @workflow.workspace_lifecycle_state.in?(WORKSPACE_EXPECTED_LIFECYCLE_STATES)
    return false if File.directory?(WorkflowWorkspace.path_for(@workflow))
    return false if WorkflowWorkspace.remote_owner_may_hold_workspace?(@workflow)

    log("step #{@step.kind} is waiting for its lost workspace to be reconstructed", kind: "system")
    defer_run(@run.id, MISSING_WORKSPACE_RETRY_DELAY)
    true
  end

  def defer_until_step_dependencies_settle
    return false if @step.dependencies_settled?

    unsettled = @step.depends_on_steps.reject(&:terminal?)
    unsettled_summary = unsettled
      .map { |dependency| "##{dependency.id} #{dependency.kind}=#{dependency.state}" }
      .join(", ")
    reason = unsettled_summary.presence || "predecessor active"
    Rails.logger.info(
      "[RunJob] step ##{@step.id} #{@step.kind} dependencies still active " \
      "(#{reason}) — deferring Run ##{@run.id} by #{STEP_DEPENDENCY_RETRY_DELAY.inspect}"
    )
    log("step #{@step.kind} is waiting for dependencies to finish: #{reason}", kind: "system")
    defer_run(@run.id, STEP_DEPENDENCY_RETRY_DELAY)
    true
  end

  def handle_running_reentry
    return false unless @run.running?

    # Side-effecting handlers like pr_open can complete externally before the
    # Run's terminal state is recorded. Always try this first so a duplicate
    # delivery does not leave a successful side effect hidden behind a failed or
    # running Run.
    if (reconciliation = RunCompletionReconciler.call(@run)).reconciled?
      log("run reconciled on re-entry: #{reconciliation.reason}")
      return true
    end

    if fresh_running_run?
      Rails.logger.info("[RunJob] Run ##{@run.id} is already running with a fresh execution lease; skipping duplicate delivery")
      return true
    end

    # Worker died mid-perform on a prior attempt (or SQ re-claimed us after a
    # process prune). Fail with worker_died so the operator gets a Retry button
    # on the dashboard.
    @run.agent_outcome = "worker_died"
    @run.fail!
    @run.save!
    # Run failure propagation may have scheduled a replacement retry when the
    # worker_died budget is not exhausted. Only fail the step explicitly when
    # no replacement work was queued by the callback.
    @step.reload
    if @step.runs.where.not(id: @run.id).active.exists? || AutoRetryAttempt.pending.where(run: @run).exists?
      log("run abandoned — worker died mid-execution; retrying automatically")
    else
      @step.fail! if @step.may_fail?
      @step.save!
      @workflow.record_run_failure!
      log("run abandoned — worker died mid-execution; use Retry to try again")
    end
    true
  end

  def pending_authorization_continuation?
    @run.running? && @run.authorization_requests.where(checkpoint_state: "resuming").exists?
  end

  def claim_authorization_continuation!
    request = @run.authorization_requests.find_by(checkpoint_state: "resuming")
    request&.complete_authorization_resume! || false
  end

  def succeed_run!(run)
    return if run.succeeded?

    run.agent_outcome = nil if run.agent_outcome == "worker_died"
    run.succeed!
    run.save!
  end

  def record_successful_step!
    with_lifecycle_lock_retry("record_success") do
      @run.reload
      @step.reload
      @workflow.reload

      return if @workflow.terminal? || @step.terminal?
      return if @run.terminal? && !@run.succeeded?

      commit_run_and_step_success!
    end
  end

  # One commit for both: separately, the Run's after-commit propagation ran
  # -- and the reconciler could observe -- a running Step whose Runs were all
  # terminal. A lock error rolls both back, and the retry reloads.
  #
  # The AASM bang events persist. Do not add a trailing `save!` here: inside
  # one transaction a no-op save clears `saved_changes`, and the
  # `saved_change_to_state` conditions on the commit callbacks -- the Step's
  # chain advance among them -- would then never fire.
  def commit_run_and_step_success!
    ActiveRecord::Base.transaction do
      # The callers check the states before this lock; a cancel can commit in
      # between. Under the lock the committed states decide: neither row is
      # written from attributes the cancel has since replaced. Captured before
      # the lock, because Lineage.lock! refreshes the in-memory records from
      # the rows it locks.
      expected_run_state = @run.state
      expected_step_state = @step.state
      # The Step is written after the Run, so the ancestry is locked first,
      # top down (NY40). Locking queries keep the Run's unsaved outcome.
      Lineage.lock!(@run)
      # The Step as committed, not as this perform last read it: two Runs of
      # one Step finishing together each read it running, and the second's
      # stale copy succeeded it again -- advancing the chain twice, which
      # created two Runs for the next Step. A locking read sees the first
      # success (see #reload_lineage_for_update!).
      @step = Step.lock.find(@step.id)
      # A locking read: a plain one answers from the snapshot Lineage.lock!
      # took before waiting on a concurrent cancel's locks (F152).
      next unless Run.lock.where(id: @run.id).pick(:state) == expected_run_state
      # A cancel of the Step wins too; another Run of the same Step having
      # succeeded it does not -- this Run still records its own success.
      next if @step.cancelled? && expected_step_state != "cancelled"

      unless @run.succeeded?
        @run.agent_outcome = nil if @run.agent_outcome == "worker_died"
        @run.succeed!
      end
      @step.succeed! if @step.may_succeed?
    end
  end

  def with_lifecycle_lock_retry(operation)
    attempts = 0

    begin
      result = yield
      record_lifecycle_lock_outcome(operation, "recovered") if attempts.positive?
      result
    rescue *LIFECYCLE_LOCK_RETRY_ERRORS => e
      attempts += 1
      exhausted = attempts >= LIFECYCLE_LOCK_RETRY_ATTEMPTS
      log_lifecycle_lock_conflict(operation, e, attempts:, exhausted:)
      if exhausted
        record_lifecycle_lock_outcome(operation, "exhausted")
        raise
      end

      sleep(0.05 * attempts) unless Rails.env.test?
      @run&.reload
      @step&.reload
      @workflow&.reload
      @job&.reload
      retry
    end
  end

  def log_lifecycle_lock_conflict(operation, error, attempts:, exhausted:)
    Rails.logger.warn({
      event: "run_lifecycle_persistence_contention",
      operation: operation,
      queue: queue_name.to_s,
      job_id: @job&.id || @run&.job_id,
      workflow_id: @workflow&.id,
      step_id: @step&.id,
      run_id: @run&.id,
      attempt: attempts,
      max_attempts: LIFECYCLE_LOCK_RETRY_ATTEMPTS,
      exhausted: exhausted,
      error_class: error.class.name,
      error_message: error.message,
      error_backtrace: (error.backtrace if exhausted)
    }.compact.to_json)
  end

  def record_lifecycle_lock_outcome(operation, outcome)
    Syrus::Metrics.counter(:syrus_run_lifecycle_lock_retries_total).increment(tags: {
      kind: operation,
      queue: queue_name.to_s,
      outcome: outcome
    })
  end

  def acquire_run_execution!
    stale_reentry = false
    acquired = false

    with_lifecycle_lock_retry("acquire_execution") do
      # Claiming the Run starts its Step and Workflow and writes its Job, so
      # the whole ancestry is locked first, top down (NY40), then the Run is
      # reloaded as with_lock would.
      Run.transaction do
        Lineage.lock!(@run)
        reload_lineage_for_update!
        claimed_attempt = claim_queued_run! if @run.queued?
        # Lost the claim: another perform started this Run between our read
        # and our write. Decide from the row as it now is.
        reload_lineage_for_update! if @run.queued? && claimed_attempt.nil?

        if @run.terminal?
          acquired = false
        elsif @run.running?
          stale_reentry = !fresh_running_run?
          acquired = false
        elsif claimed_attempt.nil?
          acquired = false
        else
          @workflow.start! if @workflow.may_start?
          @workflow.save!
          @step.start! if @step.may_start?
          @step.save!
          # Fencing token: a stalled earlier executor of this Run sees the
          # counter move at its next ensure_run_still_active! and stops.
          @run.execution_attempt = claimed_attempt
          @run.start!
          @run.save!
          @run.claimed_execution_attempt = @run.execution_attempt
          @job.update!(started_at: Time.current) if @job.started_at.nil?
          acquired = true
        end
      end
    end

    return handle_running_reentry if stale_reentry
    record_run_started_activity! if acquired

    acquired
  rescue WorkUnits::Launcher::LockConflict => e
    Rails.logger.info(
      "[RunJob] WorkUnit lock #{e.lock_key} is still owned by WorkUnit ##{e.work_unit.id}; " \
      "deferring Run ##{@run.id} by #{WORK_UNIT_LOCK_RETRY_DELAY.inspect}"
    )
    defer_run(@run.id, WORK_UNIT_LOCK_RETRY_DELAY)
    false
  end

  # Re-reads the Run and its ancestry with locking reads, which return the
  # latest committed rows. Plain reads would not: MySQL's REPEATABLE READ pins
  # them to the snapshot taken at the transaction's first plain read, which
  # Lineage.lock! makes while it collects the ancestry -- before it waits on
  # the row locks. Two performs of one Run (two RunJobs of a Job each picking
  # it up inline) then both read it as queued after the first had started
  # it, and both executed it.
  #
  # Top down (NY40), like the Lineage.lock! these rows are already held by.
  def reload_lineage_for_update!
    workflow_id = Step.where(id: @run.step_id).pick(:workflow_id) if @run.step_id
    @job = Job.lock.find(@run.job_id)
    @workflow = workflow_id && Workflow.lock.find(workflow_id)
    @step = @run.step_id && Step.lock.find(@run.step_id)
    @run.reload(lock: true)
  end

  # The queued -> running claim as a compare-and-set on the row: it matches
  # only while the Run is still queued at the attempt this perform read, so
  # of two performs racing on one Run exactly one wins, whatever either one
  # read before. Returns the claimed attempt, or nil when another perform
  # won.
  def claim_queued_run!
    attempt = @run.execution_attempt.to_i
    claimed = Run.where(id: @run.id, state: "queued", execution_attempt: attempt)
      .update_all(execution_attempt: attempt + 1)
    return attempt + 1 if claimed == 1

    Rails.logger.info("[RunJob] Run ##{@run.id} was claimed by another execution; skipping duplicate delivery")
    nil
  end

  def fresh_running_run?
    reference_time = @run.last_heartbeat_at || @run.started_at
    reference_time.present? && reference_time > FRESH_RUNNING_REENTRY_THRESHOLD.ago
  end

  def record_run_started_activity!
    WorkflowActivity.record!(
      event_type: "run_started",
      source: "run",
      run: @run,
      duration_ms: nil,
      message: "Run ##{@run.id} queued -> running.",
      metadata: {
        from_state: "queued",
        to_state: "running"
      }.merge(StateTransition.transition_metadata_for(@run)).compact
    )
  end

  def cancel_ineligible_retry_workflow!
    return false unless work_definition_for_workflow(@workflow)&.retry_workflow_attempt?

    eligibility = RetryWorkflowEligibility.call(job: @job, workflow: @workflow)
    return false if eligibility.eligible?

    log("retry workflow cancelled: #{eligibility.message}")
    @workflow.artifacts = (@workflow.artifacts || {}).merge(
      "retry_cancelled_reason" => eligibility.code,
      "retry_cancelled_at" => Time.current.iso8601
    )
    WorkUnits::WorkflowCancellation.cancel!(
      @workflow,
      reason: eligibility.code,
      artifacts: @workflow.artifacts
    )
    ReconcileJobStatesJob.perform_later if eligibility.code.in?(%w[ pr_ready superseded ])
    true
  end

  def handle_terminal_after_successful_handler
    return if expected_handler_terminal_return?

    states = {
      run: @run.state,
      step: @step.state,
      workflow: @workflow.state
    }
    message = "WARNING: #{@run.slug} handler #{@step.kind} returned successfully, " \
              "but terminal state was observed before success could be recorded " \
              "(run=#{states[:run]}, step=#{states[:step]}, workflow=#{states[:workflow]})"
    Rails.logger.warn("[RunJob] #{message}")
    log(message, kind: "system")

    reconciliation = RunCompletionReconciler.call(@run, allow_terminal_recovery: true)
    if reconciliation.reconciled?
      log("run reconciled after terminal success race: #{reconciliation.reason}", kind: "system")
    elsif reconciliation.reason.present?
      log("terminal success race could not be reconciled: #{reconciliation.reason}", kind: "system")
    end
  end

  def skip_after_step_skipped!(exception)
    log("step #{@step.kind} skipped: #{exception.message}", kind: "system")

    @run.reload
    @step.reload
    @workflow.reload
    return if @workflow.terminal? || @step.terminal?

    @run.skip! if @run.may_skip?
    @run.save!
    @step.skip_with_reason!(exception.reason)
    StepDispatcher.advance_from(@step.reload) if @step.skipped?
  end

  def park_for_operator_answer!
    log("step #{@step.kind} is awaiting an operator answer", kind: "system")
    @run.reload
    @step.reload
    @run.await_answer! if @run.may_await_answer?
    @run.save!
    @step.await_answer! if @step.may_await_answer?
    @step.save!

    question = @run.agent_questions.order(:id).last
    AgentQuestions::Resume.call(question) if question && !question.reload.active?
  end

  def block_after_cannot_proceed!(reason)
    log("BLOCKED: #{reason}", kind: "system")

    @run.reload
    @step.reload
    @workflow.reload

    @run.agent_questions.create!(
      questions: [ {
        "question" => "The agent reported it cannot proceed: #{reason}\n\nWhat should it do next?",
        "options" => nil,
        "multiple" => false
      } ],
      asked_at: Time.current
    ) unless @run.agent_questions.active.exists?

    if @run.may_block?
      @run.block!
      @run.save!
    end

    if @step.may_block?
      @step.details = @step.details.to_h.merge(
        "blocked_reason" => "agent_cannot_proceed",
        "cannot_proceed_reason" => reason
      )
      @step.block!
      @step.save!
    end

    if @workflow.may_block?
      @workflow.artifacts = (@workflow.artifacts || {}).merge(
        "cannot_proceed" => @workflow.artifact("cannot_proceed").to_h.merge(
          "reason" => reason,
          "blocked_at" => Time.current.iso8601
        )
      )
      @workflow.block!
      @workflow.save!
    end
  end

  def fail_after_transient_cannot_proceed!(reason)
    artifact = @workflow.artifact("cannot_proceed").to_h
    classification = artifact["failure_classification"].presence || "provider_transient"
    log("FAIL: cannot-proceed report classified as retryable #{classification}: #{reason}", kind: "system")
    handle_failure(
      Steps::Base::StepFailed.new(
        reason,
        problem_code: classification,
        evidence: { source: "report_cannot_proceed", details: artifact["details"] }.compact
      )
    )
  end

  def expected_handler_terminal_return?
    return false if terminal_recovery_step_after_publication?

    @workflow.cancelled? &&
      (@workflow.artifact("cancelled_reason").present? ||
       @workflow.artifact("retry_cancelled_reason").present? ||
       @workflow.artifact("start_cancelled_reason").present?)
  end

  def terminal_recovery_step_after_publication?
    return false unless RunCompletionReconciler.terminal_recovery_step_kind?(@step.kind)

    @job.reload.closure_reason.in?(%w[ pr_merged external_pr_merged ]) ||
      @workflow.artifact(Steps::MergeTrainLand::INTEGRATION_PR_ARTIFACT).present?
  end

  def work_definition_for_run(run)
    work_definition_for_workflow(run.step&.workflow) || WorkDefinitions.for(run.trigger_kind)
  rescue WorkDefinitions::UnknownKind
    WorkDefinitions.for("manual")
  end

  def work_definition_for_workflow(workflow)
    return unless workflow

    WorkDefinitions.for(workflow.work_unit&.kind || workflow.trigger_kind)
  rescue WorkDefinitions::UnknownKind
    nil
  end

  # Snapshot the diagnostic, fail the Run, and let Run/Step
  # after_update_commit fail the Step/Workflow (which fires its own
  # workspace cleanup callback). Failure accounting is per-Workflow;
  # a flaky CiFailure burst doesn't pull a Job's clean Initial down
  # with it.
  def handle_failure(exception)
    log("FAIL: #{exception.class}: #{exception.message}")

    if @run
      CaptureRunDiagnostic.capture(@run, exception, workspace: handler_workspace)
    end

    # Discard any in-memory attributes we couldn't persist. If the
    # original exception was a column-size violation
    # (ActiveRecord::ValueTooLong on `prompt` or `agent_pr_body`,
    # say) or anything else that raised mid-update, the giant
    # unsaved value is still attached to @run. A naive `fail! → save!`
    # below would try to persist it again, raise again, and the
    # Run/Step/Workflow/Job would stay wedged at :running with no
    # cascade ever firing.
    #
    # restore_attributes reverts ONLY the dirty (unpersisted)
    # attributes — keeps the in-memory record + its association
    # caches intact, unlike reload which would reset both. That
    # distinction matters for the loop-controlled grade path, where
    # the perform loop later reads @step (a sibling ivar) and would
    # be sensitive to a reload-driven association reset.
    @run&.restore_attributes

    return cancel_run_after_external_cancellation! if cancelled_while_running?

    # Failing a Run locks its whole lineage, so sibling graders of one
    # workflow failing together queue on the same Job row. The last of a
    # burst timed out, and its Run recorded the lock wait instead of the
    # grader's own result. Retried like every other lifecycle write.
    if @run&.may_fail?
      with_lifecycle_lock_retry("fail_run") { fail_run_tolerating_duplicate_diagnostic! if @run.may_fail? }
    end

    with_lifecycle_lock_retry("record_landing_failure") { record_landing_failure!(exception) }
    if @workflow && !workflow_controlled_failure? && !collector_judged_grader_failure?
      with_lifecycle_lock_retry("record_failure") do
        @workflow.record_run_failure!
      end
    end
  end

  # A cancelled Workflow or Step kills its running processes; the handler
  # then fails with no exit status. That is the cancellation, not a step
  # failure: recording it as failed showed every cancelled grader as a
  # failed grader in failure sweeps and statistics.
  def cancelled_while_running?
    return false unless @run&.may_cancel?

    @step&.reload&.cancelled? || @workflow&.reload&.cancelled?
  end

  # Only a cancelled Workflow takes the normal cancel cascade (a no-op by then).
  # A Step cancelled on its own -- review evidence superseded by a new HEAD,
  # say -- was cancelled with its cascade suppressed so the Workflow goes on;
  # cascading this Run's cancel would cancel that Workflow after all. The
  # canceller may also have cancelled the Run already, which the in-memory
  # copy does not show.
  def cancel_run_after_external_cancellation!
    log("step #{@step&.kind} ended because its #{@step&.cancelled? ? "step" : "workflow"} was cancelled", kind: "system")
    @run.reload
    return if @run.terminal?

    if @workflow&.cancelled?
      @run.cancel!
      @run.save!
    else
      @run.cancel_without_step_cascade!
    end
  end

  # A duplicate run_diagnostics.run_id insert (an unsaved diagnostic left
  # on the Run's has_one and autosaved by fail!/save!) must never mask the
  # original failure or stop the Run/Step/Workflow cascade. The diagnostic
  # row already exists, so drop the stale in-memory candidate and retry once.
  def fail_run_tolerating_duplicate_diagnostic!
    attempts = 0
    begin
      @run.fail!
      @run.save!
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?("run_diagnostics") && (attempts += 1) == 1

      log("duplicate RunDiagnostic while failing Run ##{@run.id}; retrying: #{e.message}")
      @run.association(:run_diagnostic).reset
      @run.restore_attributes
      retry
    end
  end

  def record_landing_failure!(exception)
    return unless @workflow&.trigger_kind == "auto_merge"
    return unless @job&.landing?
    return if workflow_controlled_failure?

    LandingFailureHandler.call(
      job: @job,
      reason: "#{exception.class}: #{exception.message}",
      run: @run,
      problem: (exception.problem if exception.respond_to?(:problem))
    )
  end

  def execution_owner_consistent?
    @run.user_id == @job.user_id && @workflow.user_id == @job.user_id
  end

  def fail_run_without_validation!(outcome)
    @run.update_columns(
      agent_outcome: outcome,
      state: "failed",
      finished_at: Time.current,
      updated_at: Time.current
    )
    RunResourceSummary.refresh_for(@run.reload)
  end

  # A failure is "workflow-controlled" when the dispatcher's per-kind
  # fail logic takes over (advances to next sibling for graders,
  # iterates for grader_collect / grade, or expands a declared
  # Try failure branch) rather than failing the workflow. RunJob
  # must swallow these so the outer perform loop can continue inline
  # on the next Step's Run.
  def workflow_controlled_failure?
    loop_controlled_grade_failure? || dispatcher_continued_workflow?
  end

  # A failed grader is evidence for its collect Step, not a failed Workflow:
  # the collector decides whether the failure stands, and a main-repair
  # preflight collector re-runs infrastructure failures on a fresh checkout.
  # Counted toward max_job_failures, three failed graders in a 130-grader
  # preflight failed the Workflow while 120 graders were still queued, so the
  # collector -- and its infrastructure retries -- never ran.
  COLLECTOR_JUDGED_GRADER_KINDS = %w[ grader preflight_grader ].freeze

  def collector_judged_grader_failure?
    COLLECTOR_JUDGED_GRADER_KINDS.include?(@step&.kind)
  end

  def loop_controlled_grade_failure?
    return false unless @step&.loop_id.present?
    %w[ grade grader grader_collect ].include?(@step.kind)
  end

  def dispatcher_continued_workflow?
    return false unless @workflow
    return false if @workflow.reload.terminal?

    next_inline_run.present?
  end

  # Runs created while this job drove the Workflow were not enqueued, on the
  # promise that this job would run them. It runs at most one: `except`.
  # Every other one goes back to the queue now, rather than sitting without a
  # queue job until the reconciler notices (production: ~15 a day, each
  # stalled about two minutes). The list is emptied either way, so the Run
  # this job does drive is never enqueued a second time later.
  def release_inline_held_runs!(except: nil, on_exit: false)
    ids = Array(Thread.current[::Run::INLINE_HELD_RUN_IDS]).uniq
    Thread.current[::Run::INLINE_HELD_RUN_IDS] = [] unless Thread.current[::Run::INLINE_HELD_RUN_IDS].nil?
    ids.delete(except.id) if except
    return if ids.empty?

    ::Run.where(id: ids, state: "queued").find_each(&:reenqueue!)
  rescue StandardError => e
    raise unless on_exit

    # Never mask the exception that ended the job; the reconciler still
    # re-enqueues a queued Run without a queue claim.
    Rails.logger.warn("[RunJob] could not hand back inline-held Runs #{ids.inspect}: #{e.class}: #{e.message}")
  end

  def continue_inline_after_controlled_failure
    loop do
      break if @shutdown_requested
      next_run = next_inline_run
      release_inline_held_runs!(except: @shutdown_requested ? nil : next_run)
      break unless next_run
      if @shutdown_requested
        Rails.logger.info("[RunJob] SIGTERM — yielding at step boundary for Run ##{@run.id}, successor Run ##{next_run.id} handed back to the queue")
        break
      end

      @run = next_run
      @step = @run.step
      @handler = nil
      Thread.current[:syrus_current_run] = @run

      begin
        perform_step
      rescue StandardError => e
        handle_failure(e)
        raise unless workflow_controlled_failure?
      end
    end
  end

  # The handler's WorkflowWorkspace, only when the handler had a
  # chance to instantiate one (i.e. the step actually started). Pre-
  # start failures (terminal-workflow guards, validation errors)
  # don't have a workspace — CaptureRunDiagnostic logs that as
  # "no workspace (Run failed before setup completed)".
  def handler_workspace
    return nil unless @handler
    @handler.send(:workspace)
  rescue StandardError
    nil
  end

  # After perform_step succeeds, Step.after_update_commit's
  # advance_next_step! has already fired StepDispatcher.advance_from
  # synchronously. The dispatcher either created a new Run on the
  # next runnable Step (Run#enqueue_run_job suppressed via
  # Thread.current[:syrus_in_run_job]) OR transitioned the Workflow
  # to succeeded (chain end).
  #
  # Pick up the newly-created Run if any so the worker can process it
  # in this same invocation. Returns nil when the chain is done — the
  # outer loop breaks and SQ frees the worker for the next job.
  #
  # Only a Run this perform holds: one whose creation it kept off the queue
  # (Run#enqueue_run_job). Any other queued Run already has a queue entry of
  # its own, or an inline holder in another perform -- two RunJobs of one Job
  # each picked up the same newest queued successor and executed it twice.
  def next_inline_run
    return nil if @workflow.reload.terminal?
    held_ids = Array(Thread.current[::Run::INLINE_HELD_RUN_IDS])
    return nil if held_ids.empty?

    cursor = @step.next_step
    while cursor
      queued = cursor.runs.where(state: "queued", id: held_ids).order(:created_at).last
      if queued && !self.class.distributed_parallel_run?(queued)
        return queued if inline_successor_executable_here?(queued)

        queued.reenqueue!
        log(
          "successor Run ##{queued.id} for #{cursor.kind} requires workflow storage " \
            "#{queued.workflow&.worker_storage_key}; re-enqueued instead of running inline on #{WorkerStorageIdentity.queue_key}",
          kind: "system"
        )
        return nil
      end
      cursor = cursor.next_step
    end
    nil
  end

  def inline_successor_executable_here?(queued)
    required_storage_key = queued.workflow&.worker_storage_key.presence
    return true if required_storage_key.blank?

    current_storage_key = WorkerStorageIdentity.queue_key
    return true if current_storage_key.present? && current_storage_key == required_storage_key

    required_queue = queued.resume_worker_queue
    required_queue.blank? || required_queue.to_s == queue_name.to_s
  end

  def workflow_starting?
    @workflow.queued? && @step.id == @workflow.first_step&.id
  end

  def merged_pull_request
    pr_number = @job.pr_number.presence || @job.external_pr_number.presence
    return nil if pr_number.blank?

    pr_repo = @job.effective_pr_repository
    pr = GithubClient.for(repository: pr_repo, user: @job.user).pull_request(pr_repo.slug, pr_number, bypass_cache: true)
    return nil unless pr.merged == true

    {
      number: pr_number,
      closure_reason: @job.pr_number.present? ? "pr_merged" : "external_pr_merged"
    }
  end

  def succeed_workflow_for_merged_pull_request!(merged_pr)
    @workflow.start! if @workflow.may_start?
    @workflow.save!
    @step.start! if @step.may_start?
    @step.save!
    @run.start! if @run.may_start?
    @run.save!
    @job.update!(started_at: Time.current) if @job.started_at.nil?

    log("pull request already merged (PR ##{merged_pr[:number]}); " \
        "marking #{@workflow.slug} succeeded and closing job")
    cancel_downstream_steps!(reason: "pull request already merged")

    succeed_run!(@run)
    @step.succeed!
    @step.save!

    # Step's after_update_commit normally finishes the workflow via
    # StepDispatcher. Keep this explicit as a backstop for callers
    # that execute inside a transaction where after_commit is delayed.
    @workflow.reload
    if @workflow.may_succeed?
      @workflow.succeed!
      @workflow.save!
    end

    @job.reload.cancel_active_runs_and_close!(merged_pr[:closure_reason]) if @job.open?
  end

  def cancel_downstream_steps!(reason:)
    Step.suppress_cancel_cascade do
      cursor = @step.next_step
      while cursor
        if cursor.may_skip?
          log("[#{@step.kind}] skipping downstream step ##{cursor.id} (#{cursor.kind}): #{reason}")
          cursor.skip_with_reason!(reason)
        end
        cursor = cursor.next_step
      end
    end
  end

  # Append a transcript chunk + bump the heartbeat. Resilient to blank
  # input — incoming streams (claude's stream-json, git stdout/stderr,
  # tool output) can legitimately produce empty lines, and JobLog
  # enforces presence on `chunk`. A blank chunk would crash the run
  # mid-stream. Empty chunks still bump the heartbeat (upstream is
  # producing output → sign of life), they just don't get persisted
  # as a row. Same contract as Steps::Base#log.
  def log(chunk, kind: nil, **metadata)
    text = chunk.to_s
    if text.strip.empty?
      RunHeartbeat.touch(@run)
      return
    end
    JobLog.append!(run: @run, chunk: text, kind: kind, **metadata)
    RunHeartbeat.touch(@run)
  end
end
