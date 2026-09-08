# Decides whether a set of Jobs is ready to land together as one atomic
# MergeTrain, and returns them in dependency (topological) order. Pure
# logic — no side effects.
#
# Both landing paths — an Epic's open children, and a repository's
# same-priority-tier epicless Jobs — already flow through the identical
# Workflows::MergeTrain step chain, MergeTrainFailureHandler, and dispatcher
# pattern (see config/syrus_docs/merge_train.md and
# config/syrus_docs/epicless_job_bundling.md). The only real difference is
# candidate scope, so it lives here as a Scope strategy
# (LandingBundleAssembler::Scopes::Epic / ::PriorityTier) rather than as two
# near-duplicate classes. See EPIC-316.
class LandingBundleAssembler
  Result = Data.define(:ready, :reason, :priority, :members) do
    def ready? = ready
    def job_ids = members.map(&:id)
  end

  def self.call(scope) = new(scope).call

  # Epic-backed scope: MergeTrainAssembler's former entry point.
  def self.for_epic(epic) = call(Scopes::Epic.new(epic))

  # Priority-tier-backed scope: JobBundleAssembler's former entry point.
  def self.for_repository(repository) = call(Scopes::PriorityTier.new(repository))

  # Whether `priority`'s own candidate pool forms a ready bundle on its
  # own — independent of whether a higher tier currently occupies the
  # "first ready tier" slot #for_repository would return. Note this answers
  # "is *some* owner-partition of this tier ready," not "is `job` about to
  # be bundled" — callers that need to gate one specific Job's landing must
  # use #ready_for_job? instead, or they'll block/misroute that Job over an
  # unrelated owner's ready bundle in the same tier. Priority-tier-scope
  # only; an Epic's members are never partitioned this way.
  def self.ready_for_priority?(repository, priority) = Scopes::PriorityTier.new(repository).ready_for_priority?(priority)

  # Whether `job`'s own effective-owner partition (within its own
  # repository+priority tier) forms a ready bundle. This is partition
  # readiness, not capped-member readiness: a same-partition Job beyond the
  # current bundle cap must still wait for the bundle instead of bypassing it
  # as a solo auto-merge.
  def self.ready_for_job?(job) = Scopes::PriorityTier.new(job.repository).ready_for_job?(job)

  def initialize(scope)
    @scope = scope
  end

  def call
    blocking_reason = @scope.blocking_reason
    return not_ready(blocking_reason) if blocking_reason

    @scope.partitions.each do |priority, candidates|
      ordered = LandingQueueProcessor.dependency_ordered(candidates)
      outcome = @scope.finalize(ordered)
      return not_ready(outcome.reason) if outcome.reason

      next if outcome.members.size < @scope.min_bundle_size

      return Result.new(ready: true, reason: nil, priority: priority, members: outcome.members)
    end

    not_ready(@scope.empty_reason)
  end

  private

  def not_ready(reason)
    Result.new(ready: false, reason: reason, priority: nil, members: [])
  end
end
