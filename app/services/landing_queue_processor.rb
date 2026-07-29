class LandingQueueProcessor
  MERGEABILITY_RECHECK_DELAY = 1.minute
  MERGEABILITY_WAIT_REASON = "waiting for GitHub mergeability".freeze

  # How many Jobs at the front of a repository's landing queue are
  # worth keeping rebased ahead of time. Proactive rebasing of the
  # whole approved backlog is O(N^2) waste: every merge moves the base
  # and re-dirties all the others, so rebasing PR #30 thirty times
  # before it ever reaches the front is pure churn. The front Job is
  # rebased inline by the auto_merge preflight when it lands anyway;
  # this only warms up the next couple so they're ready when they
  # advance. See PollMergeStateJob#dispatch_rebase.
  REBASE_PREFETCH_DEPTH = 3

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

    new.try_land!(job)
  end

  def try_land!(job)
    return if landing_in_progress_for_repository?(job.repository_id)

    # When merge-trains are on, an Epic child lands only as part of its
    # Epic's atomic train — never individually (that would create a
    # half-merged Epic). Route it to the train dispatcher instead of the
    # per-Job path.
    return MergeTrainDispatcher.try_dispatch!(job.epic) if merge_train_for_epic_child?(job)

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

    occupied_repo_ids = Set.new(Job.landing.pluck(:repository_id))
    landed_workflows = []

    dispatch_merge_trains!(occupied_repo_ids, landed_workflows) if AppSetting.merge_train_enabled?

    queue_entries = refresh_snapshot!(Job.landing_queue)
    queue_entries.each do |entry|
      next if occupied_repo_ids.include?(entry.job.repository_id)
      next unless entry.eligible?

      workflow = land(entry.job)
      next unless workflow

      landed_workflows << workflow
      occupied_repo_ids << entry.job.repository_id
    end

    refresh_snapshot!(Job.landing_queue) if landed_workflows.any?

    landed_workflows.first
  end

  # Dispatch an atomic merge-train for each repository whose Epic is
  # ready (all open children approved). One train per repo per tick;
  # marks the repo occupied so the per-Job loop skips it.
  def dispatch_merge_trains!(occupied_repo_ids, landed_workflows)
    candidate_epic_ids = Job.approved.where.not(epic_id: nil).distinct.pluck(:epic_id)
    return if candidate_epic_ids.empty?

    Epic.where(id: candidate_epic_ids).includes(:repository).find_each do |epic|
      next if occupied_repo_ids.include?(epic.repository_id)

      workflow = MergeTrainDispatcher.try_dispatch!(epic)
      next unless workflow

      occupied_repo_ids << epic.repository_id
      landed_workflows << workflow
    end
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
      position = if entry.eligible?
        eligible_position += 1
      end

      entry.job.update_columns(
        landing_queue_position: position,
        landing_queue_entry_position: entry.position,
        landing_queue_blocked_reason: entry.blocked_reason,
        landing_queue_entry_key: entry.landing_unit_key,
        landing_queue_blocker_job_ids: entry.blocker_jobs.map(&:id),
        landing_queue_waiting_job_ids: landing_queue_waiting_job_ids(entry),
        landing_queue_dependency_edges: entry.dependency_edges,
        landing_queue_cached_at: now
      )
    end

    clear_stale_snapshot!(scope, cached_ids)
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
    scope.where(state: %w[ approved landing ])
         .includes(:user, :repository, :epic, :parent_job, dependencies: [ :depends_on_job, :depends_on_epic ])
         .order(Arel.sql("COALESCE(jobs.approved_at, jobs.updated_at) ASC"), :id)
         .to_a
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
    job.epic_id.present? ? "epic:#{job.epic_id}" : "job:#{job.id}"
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
    recon_job_id = Epic.where(id: epic_id).pick(:reconciliation_job_id)

    Job.where(epic_id: epic_id)
       .where.not(id: unit_job_ids.to_a)
       .where.not(id: [recon_job_id].compact)
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
      raise ActiveRecord::Rollback unless job.approved?
      raise ActiveRecord::Rollback unless blockage_for(job)[:blocked_reason].blank?

      job.landing_failure_reason = nil
      job.start_landing!
      job.save!
      workflow = Workflows::AutoMerge.instantiate(job: job)
      audit(job, "landing_queue: dispatching auto-merge #{workflow.slug}")
      landed = true
    end
    return unless landed

    StepDispatcher.start_workflow(workflow)
    workflow
  end

  def landing_in_progress_for_repository?(repository_id)
    Job.landing.where(repository_id: repository_id).exists?
  end

  def merge_train_for_epic_child?(job)
    AppSetting.merge_train_enabled? && job.epic_id.present?
  end

  def blockage_for(job)
    return { blocked_reason: nil, waiting_for: nil, waiting_for_jobs: [] } if job.landing?
    return blocked("landing paused") if job.user.landing_paused?
    if job.repository.main_branch_health_enabled? && job.repository.landing_paused? && !MainHealthChangedService.fix_main_job?(job)
      return blocked("landing paused: main branch broken")
    end
    return blocked("repository archived") if job.repository.archived?
    if job.priority != "urgent" &&
       job.repository.jobs.where(priority: "urgent").where.not(state: %w[closed]).exists?
      return blocked("urgent job active")
    end
    # With merge-trains on, Epic children never land via the per-Job
    # path — they land atomically as part of their Epic's train. Keep
    # them in :approved with a clear reason; MergeTrainDispatcher picks
    # the Epic up once every child is approved.
    return blocked("waiting for Epic merge-train") if merge_train_for_epic_child?(job)
    # Don't burn a fail_landing cycle on a Job whose repo isn't set
    # up for auto-merge — that wipes the operator's approval without
    # surfacing the real misconfiguration. Keep the Job in :approved
    # with a clear blocked_reason; once the repo flips
    # auto_merge_enabled=true the queue picks it up immediately.
    return blocked("auto-merge not enabled for repository") unless job.repository.auto_merge_enabled?
    return blocked("review requested changes") if job.needs_attention_reason == "upstream_pr_changes_requested"
    return blocked("missing pull request") if job.pr_number.blank?
    # Surface a specific reason when a ci_failure workflow is the active one, so
    # operators can distinguish "agent is fixing CI" from other in-progress workflow types.
    if job.workflows.active.where(trigger_kind: "ci_failure").exists?
      return blocked("ci_failure workflow in progress on #{job.slug}")
    end
    return blocked("active workflow") if job.workflows.active.exists?
    # Block on failing or pending PR check-run state cached by PollPullRequestJob.
    # nil / "unknown" / "passing" allow landing; only "failing" and "pending" hold.
    case job.pr_checks_state
    when "failing"
      return blocked("PR checks failing on #{job.slug}")
    when "pending"
      return blocked("PR checks pending on #{job.slug}")
    end
    return blocked(MERGEABILITY_WAIT_REASON) if waiting_for_github_mergeability?(job)
    return blocked(RebaseLoopGuard::BLOCK_REASON) if RebaseLoopGuard.waiting_after_noop?(job)
    return blocked(RebaseAttemptGuard::BLOCK_REASON) if RebaseAttemptGuard.blocking_landing?(job)
    return blocked("waiting for Epic to release") if job.blocked_by_epic_before_execution?
    if job.epic
      epic = job.epic
      if epic.reconciliation_job_id.present? &&
         job.id != epic.reconciliation_job_id &&
         !epic.reconciliation_job.closed?
        return blocked("epic reconciliation pending")
      end

      unapproved_siblings = unapproved_epic_siblings(job)
      return blocked("waiting for epic siblings to be approved", waiting_for_jobs: unapproved_siblings) if unapproved_siblings.any?

      if (blocker = ci_failure_workflow_epic_sibling(job))
        return blocked("ci_failure workflow in progress on #{blocker.slug}", waiting_for_jobs: [blocker])
      end
      if (check_issue = pr_checks_unclean_epic_sibling(job))
        return blocked("PR checks #{check_issue[:label]} on #{check_issue[:sibling].slug}", waiting_for_jobs: [check_issue[:sibling]])
      end
    end

    parent = job.parent_job
    if parent && !merged?(parent)
      return blocked("waiting for #{parent.slug} to merge", parent)
    end

    dependency = job.dependencies_overridden_at.present? ? nil : unmerged_dependency(job)
    if dependency
      if dependency.depends_on_epic_id.present?
        return blocked("waiting for Epic ##{dependency.depends_on_epic.number} to complete", dependency.depends_on_epic)
      end

      waiting = dependency.pending? ? dependency.unresolved_slug : dependency.depends_on_job
      return blocked("waiting for #{dependency_label(waiting)} to merge", waiting)
    end

    { blocked_reason: nil, waiting_for: nil, waiting_for_jobs: [] }
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
