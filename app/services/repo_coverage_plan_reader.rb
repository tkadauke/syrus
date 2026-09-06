# Resolves the optional coverage plan configured in `.syrus.yml`.
#
# Thin adapter over RepoDefaultBranchSyrusYml, which owns the actual GitHub
# fetch and SyrusYml parse (shared with RepoAdversarialReviewPlan,
# RepoVisualReviewPlan, RepoGradeLoopPlan, and RepoReviewPlanPlan so
# Workflows::Base resolves the repository's default-branch config once per
# workflow instantiation instead of each plan fetching it independently).
# Previously parsed the GitHub content directly with YAML.safe_load +
# RepoCoveragePlan.from_config; now goes through the same SyrusYml#parse as
# every other plan, so a malformed `.syrus.yml` is reported consistently
# everywhere instead of only here.
class RepoCoveragePlanReader
  def self.for_job(job)
    from_syrus_yml(RepoDefaultBranchSyrusYml.for_job(job))
  end

  def self.from_syrus_yml(loaded)
    loaded.config&.coverage
  end
end
