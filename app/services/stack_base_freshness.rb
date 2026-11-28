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
#                                   no  -> rebase --onto live <prepared>
#                                          (cherry-pick the child's own
#                                          commits if it merged main),
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
  #
  # A child that merged main carries main's commits in prepared..HEAD. When
  # the parent has since been rebased onto that main, `rebase --onto` would
  # replay them on a base that already contains them, and conflict. Such a
  # child instead gets only the commits the live parent does not already
  # contain, cherry-picked onto it.
  def rebase_onto!(live, prepared, history)
    drivers = GitMergeDrivers.register!(git: @git, path: @path)
    original_head = @git.run("rev-parse", "HEAD", chdir: @path).strip
    replaying = false
    prepared = replay_base(prepared)
    if prepared.present?
      if merges_since?(prepared, live)
        replaying = true
        replay_own_commits!(live, prepared)
      else
        @git.run("rebase", "--onto", live, prepared, chdir: @path)
      end
    else
      @git.run("rebase", live, chdir: @path)
    end
  rescue GitRunner::GitError => e
    conflicts = conflicted_files(drivers)
    replaying ? abandon_replay!(original_head) : abort_rebase!
    raise RebaseConflict.new(
      "rebasing completed work onto #{@parent_ref} (#{short(live)}) failed: #{e.message}",
      evidence: evidence(prepared, live, history).merge("conflicted_files" => conflicts)
    )
  end

  CONFLICT_ARTIFACT = "stack_base_rebase_conflict".freeze

  # The base to replay the child's own commits from: the recorded prepared
  # SHA when HEAD descends from it, otherwise the nearest base any of this
  # Job's workflows recorded that HEAD does descend from.
  #
  # A retry inherited a prepared SHA naming the parent's *rewritten* head
  # while its workspace still held the work built on the parent's old head.
  # HEAD did not descend from it, so the plain-rebase fallback replayed the
  # parent's superseded commits too, and they collided add/add with their
  # rewritten versions on every retry. The old head was still on record in an
  # earlier workflow's conflict evidence.
  def replay_base(prepared)
    return prepared if usable_base?(prepared)

    recorded_bases.select { |sha| usable_base?(sha) }
      .min_by { |sha| @git.run("rev-list", "--count", "#{sha}..HEAD", chdir: @path).to_i }
  end

  def usable_base?(sha)
    sha.present? && commit_available?(sha) && descends_from?(sha)
  end

  def recorded_bases
    workflows = @workflow.job ? @workflow.job.workflows.where.not(id: @workflow.id).reorder(id: :desc).limit(20) : []
    [ @workflow, *workflows ].flat_map do |workflow|
      prepared = workflow.artifact(PREPARED_ARTIFACT)
      conflict = workflow.artifact(CONFLICT_ARTIFACT)
      [
        prepared.is_a?(Hash) ? prepared["sha"] : nil,
        conflict.is_a?(Hash) ? conflict["prepared_sha"] : nil,
        workflow.artifact("stack_parent_head_sha")
      ]
    end.compact_blank.uniq
  end

  def merges_since?(prepared, live)
    @git.run("rev-list", "--merges", "--max-count=1", "HEAD", "^#{prepared}", "^#{live}", chdir: @path).strip.present?
  end

  def replay_own_commits!(live, prepared)
    own = @git.run("rev-list", "--reverse", "--topo-order", "--no-merges", "HEAD", "^#{prepared}", "^#{live}", chdir: @path)
      .lines.map(&:strip).reject(&:blank?)
    say("child merged history the live parent already contains; replaying its #{own.size} own commit(s)")
    @git.run("reset", "--hard", live, chdir: @path)
    # --keep-redundant-commits: a child commit the parent already absorbed
    # stays as an empty commit instead of stopping the replay.
    @git.run("cherry-pick", "--keep-redundant-commits", *own, chdir: @path) if own.any?
  end

  def abandon_replay!(original_head)
    begin
      @git.run("cherry-pick", "--abort", chdir: @path)
    rescue GitRunner::GitError
      nil
    end
    @git.run("reset", "--hard", original_head, chdir: @path)
  end

  def abort_rebase!
    @git.run("rebase", "--abort", chdir: @path)
  rescue GitRunner::GitError
    nil
  end

  def conflicted_files(drivers)
    @git.run("diff", "--name-only", "--diff-filter=U", chdir: @path).lines.filter_map do |line|
      file = line.strip
      next if file.blank?

      attribute = @git.run("check-attr", "merge", "--", file, chdir: @path).split(":", 3).last.to_s.strip
      name = attribute unless attribute.in?([ "", "unspecified", "unset", "set" ])
      { "path" => file, "merge_driver" => name, "merge_driver_registered" => name.present? && drivers.registered?(name) }
    end
  rescue GitRunner::GitError
    []
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
