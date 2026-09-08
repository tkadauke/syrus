# Priority-tier-backed scope for LandingBundleAssembler: candidates are a
# repository's approved, epicless, own-PR Jobs, grouped into same-priority,
# same-effective-owner partitions. Formerly JobBundleAssembler. See
# config/syrus_docs/epicless_job_bundling.md.
#
# Gated behind Feature.epicless_job_bundling_enabled? by the caller
# (JobBundleDispatcher); this scope itself is a pure query and does not
# check the flag.
class LandingBundleAssembler::Scopes::PriorityTier
  # A single ready epicless Job falls through to the existing per-Job
  # auto_merge path rather than spinning up a bundle for one member.
  MIN_BUNDLE_SIZE = 2

  def initialize(repository)
    @repository = repository
  end

  def blocking_reason = nil

  # Urgent tiers are tried first so multiple urgent Jobs bundle together
  # ahead of everything else, mirroring the existing urgent-preemption
  # behavior in LandingQueueProcessor. An urgent Job never shares a bundle
  # with a non-urgent one because tiers are never mixed. Within a tier,
  # candidates are further partitioned by effective owner (see
  # #effective_owner_id) before dependency ordering/capping: a bundle's
  # members must all share one owner, since mixing owners would let
  # whichever Job lands as the tip member merge the integration PR under
  # its owner's credentials for changes it didn't own. An owner with only
  # one eligible Job in a tier falls through to the per-Job auto_merge path,
  # same as today's behavior for a repo/tier with too few eligible Jobs.
  #
  # Lazy so LandingBundleAssembler#call's early return on the first ready
  # partition also short-circuits candidate fetching: once e.g. `urgent` is
  # ready, `high`/`medium`/`low` are never queried, matching the original
  # JobBundleAssembler#call's per-tier early return.
  def partitions
    Job::PRIORITIES.lazy.flat_map do |priority|
      eligible_candidates(priority)
        .group_by { |job| effective_owner_id(job) }
        .values
        .map { |candidates| [ priority, candidates_with_satisfied_prerequisites(candidates) ] }
    end
  end

  def finalize(ordered)
    LandingBundleAssembler::Scopes::Outcome.new(reason: nil, members: capped_members(ordered))
  end

  def min_bundle_size = MIN_BUNDLE_SIZE

  def empty_reason = "fewer than #{MIN_BUNDLE_SIZE} same-tier epicless approved own-PR Jobs in any priority tier"

  # Whether `priority`'s own candidate pool forms a ready bundle on its own.
  def ready_for_priority?(priority)
    eligible_candidates(priority)
      .group_by { |job| effective_owner_id(job) }
      .each_value
      .any? do |candidates|
        members_for(candidates_with_satisfied_prerequisites(candidates)).any?
      end
  end

  # Whether `job`'s own effective-owner partition (within its own
  # repository+priority tier) forms a ready bundle. This deliberately returns
  # true for same-partition Jobs outside the current cap, because letting them
  # auto-merge solo would jump ahead of the bundle that should own the landing
  # slot.
  def ready_for_job?(job)
    return false if job.epic_id.present? || job.external_pr?

    owner_id = effective_owner_id(job)
    candidates = eligible_candidates(job.priority).select do |candidate|
      effective_owner_id(candidate) == owner_id
    end
    candidates = candidates_with_satisfied_prerequisites(candidates)

    candidates.any? { |candidate| candidate.id == job.id } && members_for(candidates).any?
  end

  private

  def members_for(candidates)
    return [] if candidates.size < MIN_BUNDLE_SIZE

    members = capped_members(LandingQueueProcessor.dependency_ordered(candidates))
    members.size >= MIN_BUNDLE_SIZE ? members : []
  end

  def eligible_candidates(priority)
    candidates = @repository.jobs
      .approved
      .where(epic_id: nil, priority: priority)
      .where.not(kind: "external_pr")
      .includes(:parent_job, dependencies: [ :depends_on_job, :depends_on_epic ])
      .to_a

    active_ids = WorkUnits::Ownership.active_job_ids(candidates.map(&:id))
    candidates.reject { |candidate| active_ids.include?(candidate.id) }
  end

  def effective_owner_id(job)
    job.owner_user_id.presence || job.user_id
  end

  # Cap the ordered candidate list at AppSetting.merge_train_max_size.
  # If the cap would include a dependent while excluding its prerequisite,
  # shrink the cut back so the later bundle cannot land out of order. The
  # reverse split is valid: landing a prerequisite now while leaving its
  # dependent for a later bundle preserves dependency order.
  def capped_members(ordered)
    max = AppSetting.merge_train_max_size
    return ordered if ordered.size <= max

    linked_pairs = dependency_linked_pairs(ordered)
    cut = max
    cut -= 1 while cut > 0 && cuts_off_prerequisite?(ordered, cut, linked_pairs)
    ordered.first(cut)
  end

  def dependency_linked_pairs(candidates)
    ids = candidates.map(&:id)
    dependency_pairs = JobDependency.resolved
                                    .where(job_id: ids, depends_on_job_id: ids)
                                    .pluck(:job_id, :depends_on_job_id)
    parent_pairs = candidates.filter_map { |job| [ job.id, job.parent_job_id ] if job.parent_job_id.in?(ids) }

    dependency_pairs + parent_pairs
  end

  def cuts_off_prerequisite?(ordered, cut, linked_pairs)
    included_ids = ordered.first(cut).map(&:id).to_set
    excluded_ids = ordered[cut..].map(&:id).to_set

    linked_pairs.any? do |job_id, depends_on_job_id|
      included_ids.include?(job_id) && excluded_ids.include?(depends_on_job_id)
    end
  end

  def candidates_with_satisfied_prerequisites(candidates)
    remaining = candidates

    loop do
      candidate_ids = remaining.map(&:id).to_set
      filtered = remaining.select { |candidate| prerequisites_satisfied_or_in_candidate_ids?(candidate, candidate_ids) }
      return filtered if filtered.size == remaining.size

      remaining = filtered
    end
  end

  def prerequisites_satisfied_or_in_candidate_ids?(job, candidate_ids)
    if job.parent_job_id.present? && !candidate_ids.include?(job.parent_job_id)
      return false unless merged?(job.parent_job)
    end

    return true if job.dependencies_overridden_at.present?

    job.dependencies.all? do |dependency|
      if dependency.depends_on_job_id.present?
        candidate_ids.include?(dependency.depends_on_job_id) || dependency.dependency_succeeded?
      else
        !dependency.pending? && dependency.dependency_succeeded?
      end
    end
  end

  def merged?(job)
    job&.closed? && job.closure_reason == "pr_merged"
  end
end
