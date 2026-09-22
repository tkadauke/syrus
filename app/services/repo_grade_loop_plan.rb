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

  # Only a confirmed absence drops the loop. When the config could not be
  # read before cloning -- a rate limit, a 5xx, a timeout, a parse error --
  # the loop is included and the workspace decides: grader_fanout, format and
  # generate each re-read `.syrus.yml` from the cloned repository at run time
  # and pass through when it configures nothing. Unknown therefore costs a
  # few no-op steps.
  #
  # The alternative is what this used to do: read every failure as "no
  # graders" and build the workflow without a grade loop, so a GitHub blip at
  # the wrong moment let a change through ungraded. The pre-clone read is an
  # optimization for leaving out steps that would do nothing; it must never
  # be the thing that decides whether checks run.
  def self.from_syrus_yml(loaded)
    return undetermined(loaded) unless loaded.determined?
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

  def self.undetermined(loaded)
    note = "could not read .syrus.yml before cloning (#{loaded.outcome}: #{loaded.note}); " \
           "including the check loop so the workspace's own .syrus.yml decides at run time"
    Rails.logger.warn("[RepoGradeLoopPlan] #{note}")
    Result.new(format_configured: true, generate_configured: true, graders_configured: true,
               source: loaded.source, note: note)
  end
end
