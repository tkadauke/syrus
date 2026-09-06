# Resolves the optional visual_review loop configured in `.syrus.yml`,
# falling back to the instance-wide `visual_review` Feature flag default
# when the repository hasn't configured (or couldn't fetch) a visual_review
# block, or configured one without an explicit `enabled` key.
#
# Thin adapter over RepoDefaultBranchSyrusYml, which owns the actual GitHub
# fetch and SyrusYml parse (shared with RepoAdversarialReviewPlan,
# RepoGradeLoopPlan, RepoReviewPlanPlan, and RepoCoveragePlanReader so
# Workflows::Base resolves the repository's default-branch config once per
# workflow instantiation instead of each plan fetching it independently).
class RepoVisualReviewPlan
  Result = Data.define(:enabled, :rounds, :source, :note) do
    def enabled?
      enabled
    end
  end

  def self.for_job(job)
    from_syrus_yml(RepoDefaultBranchSyrusYml.for_job(job))
  end

  def self.from_syrus_yml(loaded)
    return instance_default(source: loaded.source, note: loaded.note) unless loaded.config

    review = loaded.config.visual_review
    return instance_default(source: loaded.source, note: "no visual_review configured") unless review

    enabled = review.enabled.nil? ? Feature.visual_review_enabled? : review.enabled
    Result.new(enabled: enabled, rounds: review.rounds, source: loaded.source, note: nil)
  end

  def self.instance_default(source:, note:)
    Result.new(enabled: Feature.visual_review_enabled?, rounds: SyrusYml::DEFAULT_VISUAL_REVIEW_ROUNDS, source: source, note: note)
  end
end
