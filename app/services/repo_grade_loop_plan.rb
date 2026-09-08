# Resolves whether the repository's `.syrus.yml` configures formatters,
# generated-file checks, or CI graders, so Workflows::Base can decide
# whether to materialize the format/generate/grade retry loop for a
# workflow at all — rather than always creating Steps that just self-skip
# as no-ops when nothing is configured.
#
# Scoped to the initial/retry/pr_comment/chat_feedback "autofix" grade loop
# (see Workflows::Base.grader_retry_loop). Thin adapter over
# RepoDefaultBranchSyrusYml, which owns the actual GitHub fetch and SyrusYml
# parse (shared with RepoAdversarialReviewPlan, RepoVisualReviewPlan,
# RepoReviewPlanPlan, and RepoCoveragePlanReader so Workflows::Base resolves
# the repository's default-branch config once per workflow instantiation
# instead of each plan fetching it independently).
class RepoGradeLoopPlan
  Result = Data.define(:format_configured, :generate_configured, :graders_configured, :source, :note) do
    def any_configured?
      format_configured || generate_configured || graders_configured
    end
  end

  def self.for_job(job)
    from_syrus_yml(RepoDefaultBranchSyrusYml.for_job(job))
  end

  def self.from_syrus_yml(loaded)
    return unconfigured(source: loaded.source, note: loaded.note) unless loaded.config

    config = loaded.config
    Result.new(
      format_configured: config.formatters.is_a?(Array) && config.formatters.any?,
      generate_configured: config.generated.is_a?(Array) && config.generated.any?,
      graders_configured: config.grade.present? && config.grade.steps.any?,
      source: loaded.source,
      note: nil
    )
  end

  def self.unconfigured(source:, note:)
    Result.new(format_configured: false, generate_configured: false, graders_configured: false, source: source, note: note)
  end
end
