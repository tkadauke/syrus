# Decides whether a repository has enough same-priority, epicless,
# own-PR Jobs to land together as one atomic bundle, and returns them
# in dependency (topological) order. Pure logic — no side effects.
# Parallel to MergeTrainAssembler, but keyed on repository+priority
# tier instead of an Epic. See EPIC-246.
#
# Gated behind Feature.epicless_job_bundling_enabled? by the caller
# (JobBundleDispatcher); this class itself is a pure query and does
# not check the flag.
class JobBundleAssembler
  Result = Data.define(:ready, :reason, :priority, :members) do
    def ready? = ready
    def job_ids = members.map(&:id)
  end

  # A single ready epicless Job falls through to the existing per-Job
  # auto_merge path rather than spinning up a bundle for one member.
  MIN_BUNDLE_SIZE = 2

  def self.call(repository) = new(repository).call

  def initialize(repository)
    @repository = repository
  end

  def call
    # Urgent tiers are tried first so multiple urgent Jobs bundle together
    # ahead of everything else, mirroring the existing urgent-preemption
    # behavior in LandingQueueProcessor. An urgent Job never shares a
    # bundle with a non-urgent one because tiers are never mixed.
    Job::PRIORITIES.each do |priority|
      candidates = eligible_candidates(priority)
      next if candidates.size < MIN_BUNDLE_SIZE

      members = capped_members(LandingQueueProcessor.dependency_ordered(candidates))
      next if members.size < MIN_BUNDLE_SIZE

      return Result.new(ready: true, reason: nil, priority: priority, members: members)
    end

    not_ready("fewer than #{MIN_BUNDLE_SIZE} same-tier epicless approved own-PR Jobs in any priority tier")
  end

  private

  def eligible_candidates(priority)
    @repository.jobs
      .approved
      .where(epic_id: nil, priority: priority)
      .where.not(kind: "external_pr")
      .to_a
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

  def not_ready(reason)
    Result.new(ready: false, reason: reason, priority: nil, members: [])
  end
end
