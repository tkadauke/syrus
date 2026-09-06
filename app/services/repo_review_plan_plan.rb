# Resolves whether the repository's `.syrus.yml` opts into the review_plan
# step, so Workflows::Base can decide whether to materialize a review_plan
# Step at all -- rather than always creating one that just skips itself as
# a no-op when unconfigured.
#
# Thin adapter over RepoDefaultBranchSyrusYml, which owns the actual GitHub
# fetch and SyrusYml parse (shared with RepoAdversarialReviewPlan,
# RepoVisualReviewPlan, RepoGradeLoopPlan, and RepoCoveragePlanReader so
# Workflows::Base resolves the repository's default-branch config once per
# workflow instantiation instead of each plan fetching it independently).
# Unlike RepoAdversarialReviewPlan/RepoVisualReviewPlan, there is no
# instance-wide fallback -- review_plan is opt-in per `.syrus.yml` only,
# same as Steps::ReviewPlan's own (still-retained) runtime check.
class RepoReviewPlanPlan
  Result = Data.define(:enabled, :source, :note) do
    def enabled?
      enabled
    end
  end

  def self.for_job(job)
    from_syrus_yml(RepoDefaultBranchSyrusYml.for_job(job))
  end

  def self.from_syrus_yml(loaded)
    return disabled(source: loaded.source, note: loaded.note) unless loaded.config

    Result.new(enabled: loaded.config.review_plan, source: loaded.source, note: nil)
  end

  def self.disabled(source:, note:)
    Result.new(enabled: false, source: source, note: note)
  end
end
