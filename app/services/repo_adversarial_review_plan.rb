# Resolves the optional adversarial review loop configured in `.syrus.yml`.
#
# Thin adapter over RepoDefaultBranchSyrusYml, which owns the actual GitHub
# fetch and SyrusYml parse (shared with RepoVisualReviewPlan, RepoGradeLoopPlan,
# RepoReviewPlanPlan, and RepoCoveragePlanReader so Workflows::Base resolves
# the repository's default-branch config once per workflow instantiation
# instead of each plan fetching it independently).
class RepoAdversarialReviewPlan
  Result = Data.define(:rounds, :source, :note, :criteria) do
    def enabled?
      rounds.to_i.positive?
    end
  end

  def self.for_job(job)
    from_syrus_yml(RepoDefaultBranchSyrusYml.for_job(job))
  end

  def self.from_syrus_yml(loaded)
    return disabled(source: loaded.source, note: loaded.note) unless loaded.config

    review = loaded.config.adversarial_review
    return disabled(source: loaded.source, note: "no adversarial_review configured") unless review

    Result.new(rounds: review.rounds, source: loaded.source, note: nil, criteria: review.criteria)
  end

  def self.disabled(source:, note:)
    Result.new(rounds: 0, source: source, note: note, criteria: [])
  end
end
