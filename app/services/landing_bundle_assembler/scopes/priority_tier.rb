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
  def partitions
    Job::PRIORITIES.flat_map do |priority|
      eligible_candidates(priority)
        .group_by { |job| effective_owner_id(job) }
        .values
        .map { |candidates| [ priority, candidates ] }
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
      .any? { |candidates| members_for(candidates).any? }
  end

  # Whether `job`'s own effective-owner partition (within its own
  # repository+priority tier) forms a ready bundle.
  def ready_for_job?(job)
    return false if job.epic_id.present? || job.external_pr?

    owner_id = effective_owner_id(job)
    candidates = eligible_candidates(job.priority).select { |candidate| effective_owner_id(candidate) == owner_id }
    members_for(candidates).any?
  end

  private

  def members_for(candidates)
    return [] if candidates.size < MIN_BUNDLE_SIZE

    members = capped_members(LandingQueueProcessor.dependency_ordered(candidates))
    members.size >= MIN_BUNDLE_SIZE ? members : []
  end

  def eligible_candidates(priority)
    @repository.jobs
      .approved
      .where(epic_id: nil, priority: priority)
      .where.not(kind: "external_pr")
      .to_a
  end

  def effective_owner_id(job)
    job.owner_user_id.presence || job.user_id
  end

  # Cap the ordered candidate list at AppSetting.merge_train_max_size.
  # If the cap would fall between two candidates linked by a real
  # (resolved) JobDependency edge, shrink the cut back so the pair
  # stays together in this bundle rather than getting split — the
  # excluded tail is left for a later bundle-formation pass.
  def capped_members(ordered)
    max = AppSetting.merge_train_max_size
    return ordered if ordered.size <= max

    linked_pairs = dependency_linked_pairs(ordered)
    cut = max
    cut -= 1 while cut > 0 && crosses_dependency_edge?(ordered, cut, linked_pairs)
    ordered.first(cut)
  end

  def dependency_linked_pairs(candidates)
    ids = candidates.map(&:id)
    JobDependency.resolved.where(job_id: ids, depends_on_job_id: ids).pluck(:job_id, :depends_on_job_id)
  end

  def crosses_dependency_edge?(ordered, cut, linked_pairs)
    included_ids = ordered.first(cut).map(&:id).to_set
    excluded_ids = ordered[cut..].map(&:id).to_set

    linked_pairs.any? do |job_id, depends_on_job_id|
      (included_ids.include?(job_id) && excluded_ids.include?(depends_on_job_id)) ||
        (included_ids.include?(depends_on_job_id) && excluded_ids.include?(job_id))
    end
  end
end
