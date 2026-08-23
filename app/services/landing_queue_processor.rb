class LandingQueueProcessor
  MERGEABILITY_RECHECK_DELAY = 1.minute
  MERGEABILITY_WAIT_REASON = { key: "waiting_github_mergeability" }.freeze
  TRY_LAND_LOCK_RETRIES = 2
  TRY_LAND_LOCK_ERRORS = [
    ActiveRecord::Deadlocked,
    ActiveRecord::LockWaitTimeout
  ].freeze
  PRIORITY_ORDER_SQL = [
    "CASE jobs.priority",
    "WHEN 'urgent' THEN 0",
    "WHEN 'high' THEN 1",
    "WHEN 'medium' THEN 2",
    "WHEN 'low' THEN 3",
    "ELSE 4 END"
  ].join(" ").freeze

  # How many Jobs at the front of a repository's landing queue are
  # worth keeping rebased ahead of time. Proactive rebasing of the
  # whole approved backlog is O(N^2) waste: every merge moves the base
  # and re-dirties all the others, so rebasing PR #30 thirty times
  # before it ever reaches the front is pure churn. The front Job is
  # rebased inline by the auto_merge preflight when it lands anyway;
  # this only warms up the next couple so they're ready when they
  # advance. See PollMergeStateJob#dispatch_rebase.
  REBASE_PREFETCH_DEPTH = 3
  URGENT_ACTIVE_STATES = %w[ needs_triage triaging blocked_by_epic queued running implemented approved landing coding ].freeze

  Entry = Struct.new(:job, :position, :blocked_reason, :waiting_for, :waiting_for_jobs, :landing_unit_key, :blocker_jobs, :dependency_edges, keyword_init: true) do
    def eligible?
      blocked_reason.blank?
    end

    def job_id = job.id
  end
  LandingUnit = Struct.new(:key, :jobs, :position, keyword_init: true)
  LandingUnitEntry = Struct.new(:key, :jobs, :position, :blocker_jobs, :dependency_edges, keyword_init: true) do
    def job_ids = jobs.map(&:id)
  end

  def self.call = new.call

  def self.entries(scope = Job.all)
    new.entries(scope)
  end

  def self.landing_units(scope = Job.all)
    new.landing_units(scope)
  end

  def self.refresh_snapshot!(scope = Job.landing_queue)
    new.refresh_snapshot!(scope)
  end

  # Is this Job within the first `depth` of its repository's landing
  # queue order? Used by PollMergeStateJob to limit proactive rebases
  # to the Jobs about to land.
  def self.rebase_prefetch_candidate?(job, depth: REBASE_PREFETCH_DEPTH)
    new.rebase_prefetch_candidate?(job, depth: depth)
  end

  # Topologically sort a set of Jobs by their landing-queue
  # prerequisites (parent_job + satisfied dependencies). Used by the
  # Epic merge-train to order members for integration.
  def self.dependency_ordered(jobs)
    new.send(:dependency_order, jobs.to_a)
  end

  # The landing-unit grouping key a Job currently falls under: an Epic's
  # children always share "epic:<id>"; an epicless Job already landing as
  # part of a dispatched bundle shares "job_bundle:<merge_train_id>";
  # everything else is keyed individually as "job:<id>". Used by
  # LandingValidationPrefetcher to identify which landing_units entry a
  # currently-landing Job's own Workflow corresponds to.
  def self.landing_unit_key(job)
    new.send(:landing_unit_key, job)
  end

  # Whether this epicless, approved Job currently has enough same-tier
  # siblings to land as a JobBundleDispatcher bundle rather than solo.
  # Used by LandingValidationPrefetcher to route speculative prefetch for
  # not-yet-dispatched bundle candidates the same way it already routes
  # Epic children.
  def self.bundle_eligible_epicless_job?(job)
    new.send(:bundle_eligible_epicless_job?, job)
  end

  # Try to land a specific Job right now. Used by callers that have
  # just made a Job land-able and don't want to wait for the next
  # recurring tick — e.g. a Rebase workflow's success callback when
  # the Job is still approved. Returns the dispatched Workflow or
  # nil if the Job wasn't landable (not approved, blockage present,
  # landing already in progress for the same repository). With no Job,
  # kick the queue job immediately so it can choose the next eligible
  # approved Job.
  def self.try_land!(job = nil)
    return LandingQueueProcessorJob.perform_later unless job

    attempts = 0

    begin
      new.try_land!(job)
    rescue *TRY_LAND_LOCK_ERRORS => e
      attempts += 1
      if attempts <= TRY_LAND_LOCK_RETRIES
        Rails.logger.warn(
          "[LandingQueueProcessor] #{job.slug} try_land lock conflict (#{e.class}); " \
          "retrying attempt #{attempts}/#{TRY_LAND_LOCK_RETRIES}"
        )
        sleep(0.05 * attempts) unless Rails.env.test?
        job.reload
        retry
      end

      Rails.logger.warn(
        "[LandingQueueProcessor] #{job.slug} try_land lock conflict persisted (#{e.class}); " \
        "queueing landing processor retry"
      )
      LandingQueueProcessorJob.perform_later
      WorkEngine::Reconciler.request(source: "#{name}.try_land_lock_conflict", job: job)
      nil
    end
  end

  def try_land!(job)
    release_main_health_blocked_landing_slots_for_repair!(job) if MainHealthChangedService.fix_main_job?(job)
    release_urgent_blocked_landing_slots_for_urgent_job!(job) if job.priority == "urgent"
    return if landing_in_progress_for_repository?(job.repository_id)

    # When merge-trains are on, an Epic child lands only as part of its
    # Epic's atomic train — never individually (that would create a
    # half-merged Epic). Route it to the train dispatcher instead of the
    # per-Job path.
    return MergeTrainDispatcher.try_dispatch!(job.epic) if merge_train_for_epic_child?(job)
    # Same idea for epicless Jobs once enough same-tier candidates exist:
    # land them together as one bundle instead of racing each other for
    # the repo's single landing slot.
    return JobBundleDispatcher.try_dispatch!(job.repository) if bundle_eligible_epicless_job?(job)

    return unless job.approved?
    # For jobs that went through the operator review flow (job_approvals exist),
    # re-verify the policy is still satisfied — e.g. a final approver may have
    # been removed after the job reached :approved. Auto-approved jobs (no
    # job_approvals) bypass this gate by design.
    return if job.job_approvals.exists? && !job.approval_satisfied?
    return unless blockage_for(job)[:blocked_reason].blank?

    land(job)
  end

  def call
    start_ready_epic_sibling_jobs!

    landed_workflows = []

    queue_entries = refresh_snapshot!(Job.landing_queue)
    released_slots = release_main_health_blocked_landing_slots_for_repair_jobs!(queue_entries)
    released_slots.concat(release_urgent_blocked_landing_slots_for_urgent_jobs!(queue_entries))
    queue_entries = refresh_snapshot!(Job.landing_queue) if released_slots.any?
    occupied_repo_ids = Set.new(Job.landing.pluck(:repository_id))

    queue_entries.group_by(&:landing_unit_key).each_value do |unit_entries|
      first_entry = unit_entries.first
      repository_id = first_entry.job.repository_id
      next if occupied_repo_ids.include?(repository_id)

      workflow = if merge_train_unit?(first_entry)
        next if first_entry.blocker_jobs.any?

        MergeTrainDispatcher.try_dispatch!(first_entry.job.epic)
      elsif bundle_eligible_epicless_job?(first_entry.job)
        next if first_entry.blocker_jobs.any?

        JobBundleDispatcher.try_dispatch!(first_entry.job.repository)
      else
        entry = unit_entries.find(&:eligible?)
        land(entry.job) if entry
      end
      next unless workflow

      landed_workflows << workflow
      occupied_repo_ids << repository_id
    end

    refresh_snapshot!(Job.landing_queue) if landed_workflows.any?

    landed_workflows.first
  end

  def entries(scope = Job.all)
    position = 0
    landing_units(scope).flat_map do |unit|
      unit.jobs.map do |job|
        position += 1
        Entry.new(
          job: job,
          position: position,
          landing_unit_key: unit.key,
          blocker_jobs: unit.blocker_jobs,
          dependency_edges: unit.dependency_edges,
          **blockage_for(job)
        )
      end
    end
  end

  def refresh_snapshot!(scope = Job.landing_queue)
    queue_entries = entries(scope)
    persist_snapshot!(scope, queue_entries)
    queue_entries
  end

  def landing_units(scope = Job.all)
    chronological = queue_candidates(scope)
    preload_active_trigger_kinds(chronological)
    next_position = 1
    ordered_landing_units(landing_units_for(chronological), chronological).map do |unit|
      ordered_jobs = dependency_order(unit.jobs)
      unit_job_ids = ordered_jobs.map(&:id).to_set
      blocker_jobs = transitive_blocker_jobs_for(ordered_jobs, unit_job_ids)
      graph_jobs = ordered_jobs + blocker_jobs
      position = next_position
      next_position += ordered_jobs.size

      LandingUnitEntry.new(
        key: unit.key,
        jobs: ordered_jobs,
        position: position,
        blocker_jobs: blocker_jobs,
        dependency_edges: dependency_edges_for(graph_jobs)
      )
    end
  end

  def rebase_prefetch_candidate?(job, depth: REBASE_PREFETCH_DEPTH)
    return false unless job.repository_id

    ordered_queue(Job.where(repository_id: job.repository_id))
      .first(depth)
      .any? { |candidate| candidate.id == job.id }
  end

  private

  def persist_snapshot!(scope, queue_entries)
    now = Time.current
    cached_ids = []
    eligible_position = 0

    queue_entries.each do |entry|
      cached_ids << entry.job_id
      position = if entry.eligible? || entry.job.landing?
        eligible_position += 1
      end
      before_snapshot = landing_queue_snapshot_for(entry.job)
      after_snapshot = {
        "landing_queue_position" => position,
        "landing_queue_entry_position" => entry.position,
        "landing_queue_blocked_reason" => entry.blocked_reason,
        "landing_queue_entry_key" => entry.landing_unit_key,
        "landing_queue_blocker_job_ids" => entry.blocker_jobs.map(&:id),
        "landing_queue_waiting_job_ids" => landing_queue_waiting_job_ids(entry),
        "landing_queue_dependency_edges" => entry.dependency_edges
      }
      snapshot_changed = landing_queue_snapshot_changed?(before_snapshot, after_snapshot)

      if snapshot_changed || entry.job.landing_queue_cached_at.blank?
        entry.job.update_columns(
          landing_queue_position: after_snapshot.fetch("landing_queue_position"),
          landing_queue_entry_position: after_snapshot.fetch("landing_queue_entry_position"),
          landing_queue_blocked_reason: after_snapshot.fetch("landing_queue_blocked_reason"),
          landing_queue_entry_key: after_snapshot.fetch("landing_queue_entry_key"),
          landing_queue_blocker_job_ids: after_snapshot.fetch("landing_queue_blocker_job_ids"),
          landing_queue_waiting_job_ids: after_snapshot.fetch("landing_queue_waiting_job_ids"),
          landing_queue_dependency_edges: after_snapshot.fetch("landing_queue_dependency_edges"),
          landing_queue_cached_at: now
        )
      end
      WorkflowActivity.landing_queue_changed!(entry.job, before: before_snapshot, after: after_snapshot) if snapshot_changed
    end

    clear_stale_snapshot!(scope, cached_ids)
  end

  def landing_queue_snapshot_for(job)
    {
      "landing_queue_position" => job.landing_queue_position,
      "landing_queue_entry_position" => job.landing_queue_entry_position,
      "landing_queue_blocked_reason" => job.landing_queue_blocked_reason,
      "landing_queue_entry_key" => job.landing_queue_entry_key,
      "landing_queue_blocker_job_ids" => Array(job.landing_queue_blocker_job_ids),
      "landing_queue_waiting_job_ids" => Array(job.landing_queue_waiting_job_ids),
      "landing_queue_dependency_edges" => Array(job.landing_queue_dependency_edges)
    }
  end

  def landing_queue_snapshot_changed?(before_snapshot, after_snapshot)
    before_snapshot != JSON.parse(JSON.generate(after_snapshot))
  end

  def landing_queue_waiting_job_ids(entry)
    ids = entry.waiting_for_jobs.map(&:id)
    ids << entry.waiting_for.id if entry.waiting_for.is_a?(Job)
    ids.uniq
  end

  def clear_stale_snapshot!(scope, cached_ids)
    clear_values = {
      landing_queue_position: nil,
      landing_queue_entry_position: nil,
      landing_queue_blocked_reason: nil,
      landing_queue_entry_key: nil,
      landing_queue_blocker_job_ids: nil,
      landing_queue_waiting_job_ids: nil,
      landing_queue_dependency_edges: nil,
      landing_queue_cached_at: nil
    }

    scope.where.not(id: cached_ids).where.not(landing_queue_cached_at: nil).update_all(clear_values)
    Job.where.not(state: %w[ approved landing ]).where.not(landing_queue_cached_at: nil).update_all(clear_values)
  end

  def ordered_queue(scope)
    chronological = queue_candidates(scope)

    epic_grouped_dependency_order(chronological)
  end

  def queue_candidates(scope)
    scope.without_requested_changes_attention
         .where(state: %w[ approved landing ])
         .includes(:user, :repository, :epic, :parent_job, dependencies: [ :depends_on_job, :depends_on_epic ])
         .order(Arel.sql(PRIORITY_ORDER_SQL), Arel.sql("COALESCE(jobs.approved_at, jobs.updated_at) ASC"), :id)
         .to_a
  end

  def merge_train_unit?(entry)
    merge_train_for_epic_child?(entry.job)
  end

  def epic_grouped_dependency_order(jobs)
    landing_units = landing_units_for(jobs)
    ordered_landing_units(landing_units, jobs).flat_map do |unit|
      dependency_order(unit.jobs)
    end
  end

  def landing_units_for(jobs)
    units_by_key = {}
    jobs.each_with_index do |job, index|
      key = landing_unit_key(job)
      units_by_key[key] ||= LandingUnit.new(key: key, jobs: [], position: index)
      units_by_key[key].jobs << job
    end
    units_by_key.values
  end

  def landing_unit_key(job)
    return "epic:#{job.epic_id}" if job.epic_id.present?

    bundle_id = active_epicless_bundle_id(job)
    bundle_id ? "job_bundle:#{bundle_id}" : "job:#{job.id}"
  end

  # Only set once JobBundleDispatcher has actually persisted a bundle for
  # this Job (i.e. it's landing as part of one) — a same-tier candidate
  # pool that hasn't been dispatched yet still keys off the individual
  # Job so it can be blocked/routed per-Job by blockage_for/try_land!.
  def active_epicless_bundle_id(job)
    MergeTrainMember.joins(:merge_train)
      .where(job_id: job.id)
      .merge(MergeTrain.active.where.not(priority: nil))
      .pick(:merge_train_id)
  end

  def ordered_landing_units(units, jobs)
    by_job_id = jobs.index_by(&:id)
    unit_by_key = units.index_by(&:key)
    unit_key_by_job_id = units.each_with_object({}) do |unit, index|
      unit.jobs.each { |job| index[job.id] = unit.key }
    end
    incoming = Hash.new { |hash, key| hash[key] = Set.new }
    outgoing = Hash.new { |hash, key| hash[key] = Set.new }

    units.each { |unit| incoming[unit.key] }
    jobs.each do |job|
      job_unit_key = unit_key_by_job_id.fetch(job.id)
      landing_queue_prerequisite_ids(job).each do |prerequisite_id|
        prerequisite = by_job_id[prerequisite_id]
        next unless prerequisite

        prerequisite_unit_key = unit_key_by_job_id.fetch(prerequisite.id)
        next if prerequisite_unit_key == job_unit_key

        outgoing[prerequisite_unit_key] << job_unit_key
        incoming[job_unit_key] << prerequisite_unit_key
      end
    end

    ready = units.select { |unit| incoming[unit.key].empty? }.sort_by(&:position)
    ordered = []

    until ready.empty?
      unit = ready.shift
      ordered << unit

      outgoing[unit.key].sort_by { |key| unit_by_key.fetch(key).position }.each do |dependent_key|
        incoming[dependent_key].delete(unit.key)
        ready << unit_by_key.fetch(dependent_key) if incoming[dependent_key].empty?
      end
      ready.sort_by!(&:position)
    end

    ordered + units.reject { |unit| ordered.include?(unit) }
  end

  def dependency_order(jobs)
    by_id = jobs.index_by(&:id)
    original_index = jobs.each_with_index.to_h
    incoming = Hash.new { |hash, key| hash[key] = Set.new }
    outgoing = Hash.new { |hash, key| hash[key] = Set.new }

    jobs.each { |job| incoming[job.id] }
    jobs.each do |job|
      landing_queue_prerequisite_ids(job).each do |prerequisite_id|
        next unless by_id.key?(prerequisite_id)

        outgoing[prerequisite_id] << job.id
        incoming[job.id] << prerequisite_id
      end
    end

    ready = jobs.select { |job| incoming[job.id].empty? }
                .sort_by { |job| original_index.fetch(job) }
    ordered = []

    until ready.empty?
      job = ready.shift
      ordered << job

      outgoing[job.id].sort_by { |dependent_id| original_index.fetch(by_id.fetch(dependent_id)) }.each do |dependent_id|
        incoming[dependent_id].delete(job.id)
        ready << by_id.fetch(dependent_id) if incoming[dependent_id].empty?
      end
      ready.sort_by! { |ready_job| original_index.fetch(ready_job) }
    end

    ordered + jobs.reject { |job| ordered.include?(job) }
  end

  def landing_queue_prerequisite_ids(job)
    ids = []
    ids << job.parent_job_id if job.parent_job_id.present?
    job.dependencies.each do |dependency|
      next if job.dependencies_overridden_at.present?
      next if dependency.pending? || dependency.depends_on_job_id.blank?

      ids << dependency.depends_on_job_id
    end
    ids.uniq
  end

  def transitive_blocker_jobs_for(jobs, unit_job_ids)
    seen_ids = Set.new
    blocker_ids = Set.new
    pending_ids = jobs.flat_map { |job| landing_queue_prerequisite_ids(job) }.uniq

    until pending_ids.empty?
      batch_ids = pending_ids - seen_ids.to_a
      break if batch_ids.empty?

      seen_ids.merge(batch_ids)
      dependencies = Job.where(id: batch_ids)
                        .includes(:repository, :epic, :parent_job, dependencies: [ :depends_on_job, :depends_on_epic ])
                        .to_a
      dependencies.each do |dependency|
        blocker_ids << dependency.id if dependency_blocker?(dependency, unit_job_ids)
        pending_ids.concat(landing_queue_prerequisite_ids(dependency))
      end
    end

    blocker_ids.merge(unapproved_epic_sibling_blocker_ids_for(jobs, unit_job_ids))

    dependency_order(Job.where(id: blocker_ids.to_a)
                        .includes(:repository, :epic, :parent_job, dependencies: [ :depends_on_job, :depends_on_epic ])
                        .to_a)
  end

  def unapproved_epic_sibling_blocker_ids_for(jobs, unit_job_ids)
    epic_ids = jobs.map(&:epic_id).compact.uniq
    return [] unless epic_ids.one?

    epic_id = epic_ids.first
    Job.where(epic_id: epic_id)
       .where.not(id: unit_job_ids.to_a)
       .where.not(state: %w[ approved closed ])
       .order(:id)
       .pluck(:id)
  end

  def dependency_blocker?(job, unit_job_ids)
    !unit_job_ids.include?(job.id) && !job.closed?
  end

  def dependency_edges_for(jobs)
    job_ids = jobs.map(&:id).to_set
    jobs.flat_map do |job|
      landing_queue_prerequisite_ids(job).filter_map do |prerequisite_id|
        next unless job_ids.include?(prerequisite_id)

        { from_job_id: prerequisite_id, to_job_id: job.id }
      end
    end.uniq
  end

  def start_ready_epic_sibling_jobs!
    epic_ids = Job.approved.where.not(epic_id: nil).distinct.pluck(:epic_id)
    return if epic_ids.blank?

    Job.queued
       .where(epic_id: epic_ids)
       .includes(:repository, :workflows, dependencies: [ :depends_on_job, :depends_on_epic ])
       .find_each(&:start_pending_workflows_if_dependencies_satisfied!)
  end

  def land(job)
    workflow = nil
    landed = false
    Job.transaction do
      job.lock!
      raise ActiveRecord::Rollback if landing_in_progress_for_repository?(job.repository_id)
      raise ActiveRecord::Rollback if active_landing_workflow_for_job?(job)
      raise ActiveRecord::Rollback unless job.approved?
      raise ActiveRecord::Rollback unless blockage_for(job, consume_override: true)[:blocked_reason].blank?

      job.landing_failure_reason = nil
      job.start_landing!
      job.save!
      work_kind = job.external_pr? ? "external_pr_merge" : "auto_merge"
      workflow = WorkUnits::Launcher.instantiate(kind: work_kind, job: job)
      audit(job, "landing_queue: dispatching #{workflow.trigger_kind} #{workflow.slug}")
      WorkflowActivity.landing_workflow_dispatched!(job, workflow)
      landed = true
    end
    return unless landed

    WorkUnits::Launcher.start!(workflow)
    workflow
  end

  def landing_in_progress_for_repository?(repository_id)
    Job.landing.where(repository_id: repository_id).exists?
  end

  def release_main_health_blocked_landing_slots_for_repair_jobs!(queue_entries)
    queue_entries
      .select(&:eligible?)
      .map(&:job)
      .select { |job| MainHealthChangedService.fix_main_job?(job) }
      .flat_map { |job| release_main_health_blocked_landing_slots_for_repair!(job) }
  end

  def release_main_health_blocked_landing_slots_for_repair!(repair_job)
    return [] unless repair_job&.approved?

    release_blocked_landing_slots!(
      repository_id: repair_job.repository_id,
      except_job_id: repair_job.id,
      start_blocked_reason: StepDispatcher::MAIN_HEALTH_BLOCK_REASON,
      failure_reason: "landing start blocked: #{StepDispatcher::MAIN_HEALTH_BLOCK_REASON}",
      details: {
        "preempted_by_job_id" => repair_job.id,
        "preempted_by_job_slug" => repair_job.slug
      },
      audit_reason: "so #{repair_job.slug} can repair broken main"
    )
  end

  def release_urgent_blocked_landing_slots_for_urgent_jobs!(queue_entries)
    queue_entries
      .select(&:eligible?)
      .map(&:job)
      .select { |job| job.priority == "urgent" }
      .flat_map { |job| release_urgent_blocked_landing_slots_for_urgent_job!(job) }
  end

  def release_urgent_blocked_landing_slots_for_urgent_job!(urgent_job)
    return [] unless urgent_job&.approved?

    release_blocked_landing_slots!(
      repository_id: urgent_job.repository_id,
      except_job_id: urgent_job.id,
      start_blocked_reason: StepDispatcher::URGENT_BLOCK_REASON,
      failure_reason: "landing start blocked: #{StepDispatcher::URGENT_BLOCK_REASON}",
      details: {
        "preempted_by_job_id" => urgent_job.id,
        "preempted_by_job_slug" => urgent_job.slug
      },
      audit_reason: "so urgent #{urgent_job.slug} can land first"
    )
  end

  def release_blocked_landing_slots!(repository_id:, except_job_id:, start_blocked_reason:, failure_reason:, details:, audit_reason:)
    released = []
    active_blocked_landing_workflows(repository_id, except_job_id: except_job_id, start_blocked_reason: start_blocked_reason).each do |workflow|
      Job.transaction do
        workflow.lock!
        blocked_job = workflow.job
        blocked_job.lock!
        next unless workflow.queued?
        next unless workflow.landing_workflow?
        next unless workflow_blocked_for_start_reason?(workflow, start_blocked_reason)
        next if workflow.first_step&.runs&.exists?
        next unless blocked_job.landing?
        next unless blocked_job.may_defer_landing?

        StateTransition.with_source("system") do
          StepDispatcher.fail_unstartable_landing_workflow!(
            workflow,
            failure_reason,
            details: details
          )
          blocked_job.defer_landing!
          blocked_job.save!
        end
        audit(
          blocked_job,
          "landing_queue: deferred #{workflow.trigger_kind} #{workflow.slug} #{audit_reason}"
        )
        released << workflow
      end
    end
    released
  end

  def active_blocked_landing_workflows(repository_id, except_job_id:, start_blocked_reason:)
    (work_unit_blocked_landing_workflows(repository_id, except_job_id: except_job_id, start_blocked_reason: start_blocked_reason) +
      legacy_blocked_landing_workflows(repository_id, except_job_id: except_job_id, start_blocked_reason: start_blocked_reason)).uniq(&:id)
  end

  def work_unit_blocked_landing_workflows(repository_id, except_job_id:, start_blocked_reason:)
    WorkUnit
      .joins(workflow: :job)
      .where(state: "blocked", blocked_reason: work_unit_blocked_reason_for(start_blocked_reason))
      .where(workflows: { state: Workflow::TriggerKind::ACTIVE_STATES, trigger_kind: WorkDefinitions.landing_workflow_kinds })
      .where(jobs: { repository_id: repository_id, state: "landing" })
      .where.not(jobs: { id: except_job_id })
      .includes(:workflow)
      .order(:id)
      .map(&:workflow)
  end

  def legacy_blocked_landing_workflows(repository_id, except_job_id:, start_blocked_reason:)
    Workflow.active
      .joins(:job)
      .where(trigger_kind: WorkDefinitions.landing_workflow_kinds)
      .where(jobs: { repository_id: repository_id, state: "landing" })
      .where.not(jobs: { id: except_job_id })
      .reorder(:id)
      .select { |workflow| workflow.artifact("start_blocked_reason") == start_blocked_reason }
  end

  def workflow_blocked_for_start_reason?(workflow, start_blocked_reason)
    WorkUnits::StartBlock.for(workflow).blocked_for?(start_blocked_reason)
  end

  def work_unit_blocked_reason_for(start_blocked_reason)
    WorkUnits::StartBlock.work_unit_reason_for(start_blocked_reason)
  end

  def active_landing_workflow_for_job?(job)
    job.workflows.active.where(trigger_kind: WorkDefinitions.landing_workflow_kinds).exists?
  end

  def merge_train_for_epic_child?(job)
    AppSetting.merge_train_enabled? &&
      job.epic_id.present?
  end

  # Parallels merge_train_for_epic_child?: once enough same-tier epicless
  # own-PR candidates exist for the repo, the Job lands only as part of
  # JobBundleDispatcher's bundle rather than racing for the landing slot
  # on its own. A single ready candidate falls through to the ordinary
  # per-Job auto_merge path (JobBundleAssembler::MIN_BUNDLE_SIZE).
  def bundle_eligible_epicless_job?(job)
    return false unless Feature.epicless_job_bundling_enabled?
    return false if job.epic_id.present? || job.external_pr?

    JobBundleAssembler.ready_for_priority?(job.repository, job.priority)
  end

  def blockage_for(job, consume_override: false)
    if job.landing?
      if (retry_after = active_landing_start_blocker_retry_after(job))
        return blocked({ key: "landing_start_blocked_retrying", params: { retry_at: retry_after.iso8601 } })
      end

      return { blocked_reason: nil, waiting_for: nil, waiting_for_jobs: [] }
    end
    return blocked({ key: "manual_pause" }) if job.manual_paused?
    return override_or_block(job, { key: "landing_paused" }, consume: consume_override) if job.user.landing_paused?
    if job.repository.main_branch_health_enabled? &&
       AppSetting.strict_main_branch_breakage_policy? &&
       job.repository.landing_paused? &&
       job.repository.main_health_broken? &&
       !MainHealthChangedService.fix_main_job?(job)
      return override_or_block(job, { key: "landing_paused_main_broken" }, consume: consume_override)
    end
    return override_or_block(job, { key: "repository_archived" }, consume: consume_override) if job.repository.archived?
    if job.priority != "urgent" && unrelated_urgent_job_active_for_repository?(job)
      return override_or_block(job, { key: "urgent_job_active" }, consume: consume_override)
    end
    return override_or_block(job, { key: "waiting_epic_release" }, consume: consume_override) if job.blocked_by_epic_before_execution?
    # With merge-trains on, Epic children never land via the per-Job
    # path — they land atomically as part of their Epic's train. Keep
    # them in :approved with a clear reason; MergeTrainDispatcher picks
    # the Epic up once every child is approved.
    return override_or_block(job, { key: "waiting_epic_merge_train" }, consume: consume_override) if merge_train_for_epic_child?(job)
    # Same idea, epicless: once a same-tier bundle is forming, keep the
    # Job in :approved with a clear reason instead of letting it try to
    # land solo — JobBundleDispatcher picks the group up atomically.
    return override_or_block(job, { key: "waiting_epicless_bundle" }, consume: consume_override) if bundle_eligible_epicless_job?(job)
    if (retry_after = landing_start_blocker_retry_after(job))
      return blocked({ key: "landing_start_blocked_retrying", params: { retry_at: retry_after.iso8601 } })
    end
    # Don't burn a fail_landing cycle on a Job whose repo isn't set
    # up for auto-merge — that wipes the operator's approval without
    # surfacing the real misconfiguration. Keep the Job in :approved
    # with a clear blocked_reason; once the repo flips
    # auto_merge_enabled=true the queue picks it up immediately. Simple-mode
    # Epic children can opt in per Job without exposing the repository setting.
    return override_or_block(job, { key: "auto_merge_not_enabled" }, consume: consume_override) unless job.auto_merge_enabled?
    return override_or_block(job, { key: "review_requested_changes" }, consume: consume_override) if job.needs_attention_reason == Job::REQUESTED_CHANGES_ATTENTION_REASON
    return blocked({ key: "missing_pull_request" }) if job.pr_number.blank? && job.external_pr_number.blank?
    # Surface a specific reason when a ci_failure workflow is the active one, so
    # operators can distinguish "agent is fixing CI" from other in-progress workflow types.
    # One pluck covers both checks instead of two separate EXISTS round trips per Job.
    active_trigger_kinds = active_trigger_kinds_for(job)
    if active_trigger_kinds.include?("ci_failure")
      return override_or_block(job, { key: "ci_failure_in_progress", params: { slug: job.slug } }, consume: consume_override)
    end
    return override_or_block(job, { key: "active_workflow" }, consume: consume_override) if active_trigger_kinds.any?
    # Block on failing or pending PR check-run state cached by PollPullRequestJob.
    # nil / "unknown" / "passing" allow landing; only "failing" and "pending" hold.
    if no_effective_ci_repair?(job) && job.pr_checks_state.in?(%w[failing pending])
      return blocked({ key: "ci_repair_no_effective_change", params: { slug: job.slug } })
    end
    case job.pr_checks_state
    when "failing"
      return blocked({ key: "pr_checks_failing", params: { slug: job.slug } })
    when "pending"
      return blocked({ key: "pr_checks_pending", params: { slug: job.slug } })
    end
    return override_or_block(job, MERGEABILITY_WAIT_REASON, consume: consume_override) if waiting_for_github_mergeability?(job)
    return override_or_block(job, { key: "waiting_github_mergeability_noop" }, consume: consume_override) if RebaseLoopGuard.waiting_after_noop?(job)
    return override_or_block(job, { key: "rebase_cap_reached" }, consume: consume_override) if RebaseAttemptGuard.blocking_landing?(job)
    if job.epic
      unapproved_siblings = unapproved_epic_siblings(job)
      return override_or_block(job, { key: "waiting_epic_siblings" }, waiting_for_jobs: unapproved_siblings, consume: consume_override) if unapproved_siblings.any?

      if (blocker = ci_failure_workflow_epic_sibling(job))
        return override_or_block(job, { key: "ci_failure_in_progress", params: { slug: blocker.slug } }, waiting_for_jobs: [blocker], consume: consume_override)
      end
      if (check_issue = pr_checks_unclean_epic_sibling(job))
        check_key = no_effective_ci_repair?(check_issue[:sibling]) ? "ci_repair_no_effective_change" :
          (check_issue[:label] == "failing" ? "pr_checks_failing" : "pr_checks_pending")
        return blocked({ key: check_key, params: { slug: check_issue[:sibling].slug } }, waiting_for_jobs: [check_issue[:sibling]])
      end
    end

    parent = job.parent_job
    if parent && !merged?(parent)
      return override_or_block(job, { key: "waiting_to_merge", params: { slug: parent.slug } }, parent, consume: consume_override)
    end

    dependency = job.dependencies_overridden_at.present? ? nil : unmerged_dependency(job)
    if dependency
      if dependency.depends_on_epic_id.present?
        return override_or_block(job, { key: "waiting_epic_to_complete", params: { number: dependency.depends_on_epic.number } }, dependency.depends_on_epic, consume: consume_override)
      end

      waiting = dependency.pending? ? dependency.unresolved_slug : dependency.depends_on_job
      return override_or_block(job, { key: "waiting_to_merge", params: { slug: dependency_label(waiting) } }, waiting, consume: consume_override)
    end

    { blocked_reason: nil, waiting_for: nil, waiting_for_jobs: [] }
  end

  def override_or_block(job, reason, waiting_for = nil, waiting_for_jobs: [], consume: false)
    return blocked(reason, waiting_for, waiting_for_jobs: waiting_for_jobs) unless landing_blocker_override_matches?(job, reason)

    if consume
      job.update_columns(landing_blocker_override_used_at: Time.current, updated_at: Time.current)
      audit(job, "landing_queue: one-shot override consumed for blocker #{reason[:key]}; reason=#{job.landing_blocker_override_reason}")
    end
    { blocked_reason: nil, waiting_for: nil, waiting_for_jobs: [] }
  end

  def landing_blocker_override_matches?(job, reason)
    key = reason[:key].to_s
    return false if key.in?(LandingBlockerOverride::NON_OVERRIDABLE_KEYS)
    return false if job.landing_blocker_override_used_at.present?

    job.landing_blocker_override_key.to_s == key
  end

  def blocked(reason, waiting_for = nil, waiting_for_jobs: [])
    { blocked_reason: reason, waiting_for: waiting_for, waiting_for_jobs: waiting_for_jobs }
  end

  def waiting_for_github_mergeability?(job)
    return false unless AutoMergeGate::TRANSIENT_MERGEABLE_STATES.include?(job.github_mergeable_state.to_s)
    return false if job.local_mergeable == false
    return false if job.mergeability_checked_at.blank?

    job.mergeability_checked_at > MERGEABILITY_RECHECK_DELAY.ago
  end

  def landing_start_blocker_retry_after(job)
    return unless LandingQueueReentry.landing_start_blocker?(job.landing_failure_reason)

    workflow = job.workflows
      .where(trigger_kind: WorkDefinitions.landing_workflow_kinds)
      .reorder(id: :desc)
      .detect { |wf| WorkUnits::StartBlock.for(wf).landing_start_blocker? }
    retry_after = workflow ? WorkUnits::StartBlock.for(workflow).next_check_at : nil
    retry_after if retry_after&.future?
  end

  def active_landing_start_blocker_retry_after(job)
    workflow = job.workflows
      .active
      .where(trigger_kind: WorkDefinitions.landing_workflow_kinds)
      .reorder(id: :desc)
      .detect { |wf| WorkUnits::StartBlock.for(wf).landing_start_blocker? }
    retry_after = workflow ? WorkUnits::StartBlock.for(workflow).next_check_at : nil
    retry_after if retry_after&.future?
  end

  def parse_time(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # Generalized from "is a single urgent Job active" to "does the active
  # landing unit for this repo contain an urgent-priority member" so an
  # urgent epicless bundle (grouped under one job_bundle: landing unit,
  # never mixed-tier per JobBundleAssembler) preempts non-urgent Jobs the
  # same way a lone urgent Job always has. Grouping (rather than checking
  # each urgent Job individually) matters once landing units exist: if
  # `job` is a prerequisite for *any* member of an active urgent unit,
  # the whole unit is "related" and must not block `job` — blocking it
  # would deadlock the unit against its own prerequisite.
  def unrelated_urgent_job_active_for_repository?(job)
    active_urgent_jobs = job.repository.jobs
      .where(priority: "urgent")
      .where(state: URGENT_ACTIVE_STATES)
      .where.not(id: job.id)
      .to_a
    return false if active_urgent_jobs.empty?

    active_urgent_jobs.group_by { |urgent_job| landing_unit_key(urgent_job) }.each_value.any? do |unit_jobs|
      unit_jobs.none? { |urgent_job| landing_queue_prerequisite_ids(urgent_job).include?(job.id) }
    end
  end

  def unapproved_epic_siblings(job)
    job.epic.work_jobs
       .where.not(id: job.id)
       .where.not(state: %w[ approved closed ])
       .order(:id)
       .to_a
  end

  def ci_failure_workflow_epic_sibling(job)
    job.epic.work_jobs
       .where.not(id: job.id)
       .joins(:workflows)
       .where(workflows: { state: %w[running queued], trigger_kind: "ci_failure" })
       .order(:id)
       .first
  end

  def pr_checks_unclean_epic_sibling(job)
    base = job.epic.work_jobs.where.not(id: job.id).where.not(state: "closed")

    failing = base.where(pr_checks_state: "failing").order(:id).first
    return { sibling: failing, label: "failing" } if failing

    pending_sibling = base.where(pr_checks_state: "pending").order(:id).first
    return { sibling: pending_sibling, label: "pending" } if pending_sibling

    nil
  end

  def no_effective_ci_repair?(job)
    job.landing_failure_reason.to_s.start_with?(PollPullRequestJob::NO_EFFECTIVE_CI_REPAIR_REASON)
  end

  def preload_active_trigger_kinds(jobs)
    job_ids = jobs.map(&:id)
    @active_trigger_kinds_by_job_id = if job_ids.empty?
      {}
    else
      Workflow.active
        .where(job_id: job_ids)
        .pluck(:job_id, :trigger_kind)
        .group_by(&:first)
        .transform_values { |rows| rows.map(&:second) }
    end
  end

  def active_trigger_kinds_for(job)
    if defined?(@active_trigger_kinds_by_job_id) && @active_trigger_kinds_by_job_id
      return Array(@active_trigger_kinds_by_job_id[job.id])
    end

    job.workflows.active.pluck(:trigger_kind)
  end

  def merged?(job)
    job.closed? && job.closure_reason == "pr_merged"
  end

  def unmerged_dependency(job)
    job.dependencies.includes(:depends_on_job, :depends_on_epic).find do |dependency|
      dependency.pending? || !dependency.dependency_succeeded?
    end
  end

  def dependency_label(waiting)
    return waiting if waiting.is_a?(String)

    waiting.slug
  end

  def audit(job, message)
    run = job.current_run
    return unless run

    JobLog.append!(run: run, chunk: message, kind: "system")
  end
end
