# Finalization barrier for Jobs whose PR base is another Job's branch.
#
# A stacked child records the parent head it was prepared against, but the
# parent can be rebased and force-pushed while the child is still working.
# Cancelling useful in-flight work for that is wasteful, so the child is
# allowed to finish; this barrier runs immediately before publication (and
# before the Job becomes dependency-satisfying) and proves the completed
# branch descends from the *live* parent head.
#
#   fetch live parent -> descends?  yes -> fresh
#                                   no  -> rebase --onto live <prepared>,
#                                          post-rebase validation,
#                                          fetch live parent again ...
#
# Retries are bounded; a parent that never holds still ends in
# AwaitingStableBase, which keeps the completed work and refuses to publish
# stale ancestry. Whole-stack restacking stays the recovery path for stacks
# that were already published stale.
class StackBaseFreshness
  PREPARED_ARTIFACT = "stack_base_prepared".freeze
  AWAITING_ARTIFACT = "awaiting_stable_base".freeze
  MAX_REBASES = 3

  Result = Data.define(:status, :parent_ref, :prepared_sha, :live_sha, :rebases) do
    def rebased? = rebases.positive?
  end

  class Error < StandardError
    attr_reader :evidence

    def initialize(message, evidence: {})
      super(message)
      @evidence = evidence
    end
  end

  # The parent kept moving (or could not be proven stable) within the bound.
  class AwaitingStableBase < Error; end
  # Replaying the child's commits onto the live parent conflicts.
  class RebaseConflict < Error; end
  # The rebased tree failed post-rebase validation.
  class ValidationFailed < Error; end

  # Whether the Job's PR base is another open Job's branch in the same repo.
  def self.applicable?(job, base_branch)
    parent = job.parent_job
    parent.present? &&
      parent.repository_id == job.repository_id &&
      parent.open? &&
      parent.branch_name.present? &&
      parent.branch_name == base_branch.to_s
  end

  # Records the parent head the workspace was prepared from. First write wins:
  # a re-clone later in the Workflow must not overwrite the original basis.
  def self.record_prepared!(workflow, ref:, sha:)
    return if sha.blank? || workflow.artifact(PREPARED_ARTIFACT).is_a?(Hash)

    workflow.set_artifact!(PREPARED_ARTIFACT, { "ref" => ref, "sha" => sha, "recorded_at" => Time.current.iso8601 })
  end

  # fetch_live:  -> String sha of the live parent head (fetches into the workspace)
  # validator:   -> true/false (or raises) post-rebase validation
  def initialize(workflow:, git:, path:, parent_ref:, fetch_live:, validator:, max_rebases: MAX_REBASES, log: nil)
    @workflow = workflow
    @git = git
    @path = path.to_s
    @parent_ref = parent_ref
    @fetch_live = fetch_live
    @validator = validator
    @max_rebases = max_rebases
    @log = log
  end

  def ensure_fresh!
    rebases = 0
    history = []
    prepared = prepared_sha

    loop do
      live = @fetch_live.call.to_s
      raise AwaitingStableBase.new("could not resolve live head of #{@parent_ref}", evidence: evidence(prepared, live, history)) if live.blank?

      if descends_from?(live)
        record_prepared!(live)
        return Result.new(rebases.zero? ? :fresh : :rebased, @parent_ref, prepared, live, rebases)
      end

      if rebases >= @max_rebases
        raise AwaitingStableBase.new(
          "#{@parent_ref} moved #{rebases + 1} times while rebasing; no stable base after #{@max_rebases} attempts",
          evidence: evidence(prepared, live, history)
        )
      end

      history << live
      rebases += 1
      say("stack base #{@parent_ref} moved (#{short(prepared)} -> #{short(live)}); rebasing completed work (attempt #{rebases}/#{@max_rebases})")
      rebase_onto!(live, prepared, history)
      validate!(live, prepared, history)
      prepared = live
      record_prepared!(live)
    end
  end

  # True when HEAD contains the given commit.
  def descends_from?(sha)
    @git.run("merge-base", "--is-ancestor", sha, "HEAD", chdir: @path)
    true
  rescue GitRunner::GitError
    false
  end

  private

  def prepared_sha
    artifact = @workflow.artifact(PREPARED_ARTIFACT)
    sha = artifact["sha"] if artifact.is_a?(Hash)
    sha.presence || @workflow.artifact("stack_parent_head_sha").to_s.presence
  end

  def record_prepared!(sha)
    @workflow.set_artifact!(PREPARED_ARTIFACT, { "ref" => @parent_ref, "sha" => sha, "recorded_at" => Time.current.iso8601 })
  end

  # Replays only the child's own commits (prepared..HEAD) so commits of the
  # superseded parent history are not carried over. Without a usable prepared
  # SHA, falls back to a plain rebase onto the live head.
  def rebase_onto!(live, prepared, history)
    if prepared.present? && commit_available?(prepared) && descends_from?(prepared)
      @git.run("rebase", "--onto", live, prepared, chdir: @path)
    else
      @git.run("rebase", live, chdir: @path)
    end
  rescue GitRunner::GitError => e
    begin
      @git.run("rebase", "--abort", chdir: @path)
    rescue GitRunner::GitError
      nil
    end
    raise RebaseConflict.new(
      "rebasing completed work onto #{@parent_ref} (#{short(live)}) failed: #{e.message}",
      evidence: evidence(prepared, live, history)
    )
  end

  def validate!(live, prepared, history)
    outcome = @validator.call
    return if outcome != false

    raise ValidationFailed.new(
      "post-rebase validation failed after rebasing onto #{@parent_ref} (#{short(live)})",
      evidence: evidence(prepared, live, history)
    )
  end

  def commit_available?(sha)
    @git.run("cat-file", "-e", "#{sha}^{commit}", chdir: @path)
    true
  rescue GitRunner::GitError
    false
  end

  def evidence(prepared, live, history)
    {
      "parent_ref" => @parent_ref,
      "prepared_sha" => prepared,
      "live_sha" => live,
      "observed_parent_heads" => history,
      "max_rebases" => @max_rebases
    }.compact
  end

  def short(sha) = sha.to_s[0, 8].presence || "unknown"

  def say(message) = @log&.call("stack_base_freshness: #{message}")
end
