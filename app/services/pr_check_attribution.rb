# Answers the question the landing gate could not: when a Job's PR checks are
# failing, is that *this Job's* fault, or did it inherit a failure that is
# already red on the branch it is built on?
#
# Syrus has always been able to make this call for its own grader steps
# (Adjudicators::InheritedGraderFailure -> MainBranchFailureClassifier). For
# GitHub check runs it could not, because the Job recorded only a single
# `pr_checks_state` enum with no record of *which* checks failed. Both halves now
# exist -- `jobs.pr_checks_failing_names` and
# `main_branch_health_checks.ci_failed_checks` -- and this is the comparison.
#
# Deliberately conservative. Check-run names are coarse: one "rspec" check can
# be red on main for spec A and red on a PR for specs A *and* B, and by name
# alone those look identical. So `inherited` means "every failing check here is
# also failing on the base" -- evidence that the Job is not obviously at fault,
# NOT proof that it is clean. That is why an inherited verdict makes the landing
# block overridable rather than landing the Job automatically.
class PrCheckAttribution
  Result = Data.define(:verdict, :failing_names, :base_failing_names, :base_sha, :reason) do
    def inherited? = verdict == :inherited
    def own? = verdict == :own
    def unknown? = verdict == :unknown

    # Failing checks that are NOT red on the base -- the ones this Job has to
    # answer for.
    def own_names = failing_names - base_failing_names

    def to_h
      {
        "verdict" => verdict.to_s,
        "failing_names" => failing_names,
        "base_failing_names" => base_failing_names,
        "own_names" => own_names,
        "base_sha" => base_sha,
        "reason" => reason
      }.compact
    end
  end

  def self.for(job) = new(job).call

  def initialize(job)
    @job = job
  end

  def call
    return unknown("no_failing_check_names_recorded") if failing_names.blank?
    return unknown("no_base_health_record") if base_check.nil?
    # Only a *settled broken* base tells us anything. A healthy or unknown base
    # means these failures are this Job's to explain.
    return own("base_not_broken") unless base_check.ci_health == "broken"

    if (failing_names - base_failing_names).empty?
      Result.new(verdict: :inherited, failing_names: failing_names, base_failing_names: base_failing_names,
                 base_sha: base_check.sha, reason: "every_failing_check_also_failing_on_base")
    else
      own("checks_failing_only_here")
    end
  end

  private

  attr_reader :job

  def failing_names
    @failing_names ||= normalize(job.pr_checks_failing_names)
  end

  def base_failing_names
    @base_failing_names ||= base_check ? normalize(base_check.ci_failed_checks) : []
  end

  # Prefer the PR's own recorded base SHA; fall back to the repository's most
  # recent settled CI poll, which is the best available statement of "what is
  # red on main right now".
  def base_check
    return @base_check if defined?(@base_check)

    @base_check = exact_base_check || latest_repository_check
  end

  def exact_base_check
    sha = job.mergeability_base_sha.presence
    return nil if sha.blank?

    MainBranchHealthCheck.where(repository_id: job.repository_id, sha: sha)
                         .where.not(ci_health: "unknown")
                         .recent.first
  end

  def latest_repository_check
    MainBranchHealthCheck.where(repository_id: job.repository_id, source: "ci_poll")
                         .where(ci_health: MainBranchHealthCheck::SETTLED_CI_HEALTH)
                         .recent.first
  end

  # Both sides store check runs as either bare names or richer hashes, depending
  # on which collector wrote them. Normalize to a sorted, unique name list.
  def normalize(raw)
    Array(raw).filter_map { |entry|
      case entry
      when String then entry
      when Hash then entry["name"] || entry[:name]
      end
    }.map(&:to_s).reject(&:blank?).uniq.sort
  end

  def own(reason)
    Result.new(verdict: :own, failing_names: failing_names, base_failing_names: base_failing_names,
               base_sha: base_check&.sha, reason: reason)
  end

  def unknown(reason)
    Result.new(verdict: :unknown, failing_names: failing_names, base_failing_names: base_failing_names,
               base_sha: base_check&.sha, reason: reason)
  end
end
