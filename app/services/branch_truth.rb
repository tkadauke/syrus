# Which copy of a branch is true: the one Syrus is about to publish (local
# HEAD in a workspace) or the one already on the remote.
#
# Every place Syrus publishes a branch -- pr_open, the push step, the rebase
# workflow's force push, the stack force push, merge-train integration
# publishes -- used to answer this question on its own, with a different
# subset of "is it an ancestor?", "does `git cherry` say the remote patches
# survived?", and "did Syrus push that SHA before?". Each subset was wrong in
# a different production incident: an Epic-wide stack rebase rewrote a PR
# branch while a workflow still held the pre-rebase output, and pr_open called
# a remote that already contained every one of its commits "changed before
# Syrus could push".
#
# BranchTruth is the one decision rule. It first classifies the relationship
# between the two heads (`relation`), then derives what a publisher should do
# (`outcome`):
#
#   relation               outcome
#   ---------------------  -----------------------------------------------
#   absent                 publish (create the branch; lease: must not exist)
#   identical              up_to_date
#   fast_forward           publish (local descends from remote)
#   rewrite                publish (remote is exactly the head local was
#                          deliberately rewritten from -- a protected head)
#   remote_ahead           adopt_remote (remote descends from local)
#   equivalent             adopt_remote, or publish when only local is on
#                          the fresh base (same patches, local rebased later)
#   remote_contains_local  adopt_remote, or ambiguous when the remote's
#                          extra content sits on a stale base
#   local_contains_remote  publish, or rebase_onto_remote when the remote is
#                          on a fresher base than local (it was rebased under
#                          us; replaying our extra commits onto it is right,
#                          overwriting it would revert the rebase)
#   diverged               ambiguous (different content on both sides)
#
# "Patch content" is compared with patch ids (`git cherry`), ignoring commits
# whose patch is already on `base` -- a stack rebase re-creates the parent's
# commits, and those must not read as this branch's work on either side.
# Merge commits have no patch id; an unmatched merge on one side means that
# side's content cannot be proven present on the other. Identical trees are
# equivalent whatever the history says.
#
# Freshness: a side is fresh when `base` is its ancestor. Without a base,
# freshness is unknown and the rule assumes the remote is at least as fresh
# as local -- so it never overwrites a remote it cannot prove stale.
#
# Classification never mutates the repository. Any git failure yields the
# `unknown` relation, whose outcome is `ambiguous`: callers fail closed.
class BranchTruth
  RELATIONS = %i[
    absent identical fast_forward rewrite remote_ahead equivalent
    remote_contains_local local_contains_remote diverged unknown
  ].freeze
  OUTCOMES = %i[publish up_to_date adopt_remote rebase_onto_remote ambiguous].freeze

  # The named recovery for an ambiguous outcome. The reconciler and the
  # operator's "retry from the current PR branch" action already perform it.
  AMBIGUOUS_RECOVERY = "retry_from_current_pr_branch".freeze

  # Workflow artifact recording that a publisher took the remote head as the
  # published result instead of pushing its own copy.
  ADOPTED_ARTIFACT = "branch_truth_adopted_remote".freeze

  Result = Data.define(:relation, :outcome, :local_sha, :remote_sha, :base_sha, :local_fresh, :remote_fresh, :evidence) do
    def publish? = outcome == :publish
    def up_to_date? = outcome == :up_to_date
    def adopt_remote? = outcome == :adopt_remote
    def rebase_onto_remote? = outcome == :rebase_onto_remote
    def ambiguous? = outcome == :ambiguous

    # Expected remote value for `--force-with-lease=<ref>:<lease_sha>`. Empty
    # means "the ref must not exist", which is exactly the absent case.
    def lease_sha = remote_sha.to_s

    # Whether publishing replaces history (needs a lease) rather than
    # fast-forwarding or creating the branch.
    def rewrites_remote? = publish? && relation.in?(%i[rewrite equivalent local_contains_remote])

    def to_h
      {
        "relation" => relation.to_s,
        "outcome" => outcome.to_s,
        "local_sha" => local_sha,
        "remote_sha" => remote_sha,
        "base_sha" => base_sha,
        "local_fresh" => local_fresh,
        "remote_fresh" => remote_fresh,
        "recommended_recovery" => (AMBIGUOUS_RECOVERY if ambiguous?)
      }.merge(evidence.to_h).compact
    end
  end

  # git:            a GitRunner (or compatible) the workspace is read through
  # chdir:          the repository to read
  # local:          the head about to be published (a ref or SHA, normally "HEAD")
  # remote:         the observed remote head SHA, or nil when the branch is absent
  # base:           the branch's intended base tip (ref or SHA); optional
  # rewritten_from: SHAs local was deliberately rewritten from (the protected
  #                 heads a rebase started at); a remote at one of them is
  #                 replaced, not compared
  def self.classify(git:, chdir:, local:, remote:, base: nil, rewritten_from: [])
    new(git: git, chdir: chdir, local: local, remote: remote, base: base, rewritten_from: rewritten_from).classify
  end

  # The rule itself, separated from git so it can be stated and tested as a
  # pure function of the classified relation and freshness.
  def self.outcome_for(relation, local_fresh:, remote_fresh:)
    local_strictly_fresher = local_fresh == true && remote_fresh != true
    remote_strictly_fresher = remote_fresh == true && local_fresh != true

    case relation
    when :absent, :fast_forward, :rewrite then :publish
    when :identical then :up_to_date
    when :remote_ahead then :adopt_remote
    when :equivalent then local_strictly_fresher ? :publish : :adopt_remote
    when :remote_contains_local then local_strictly_fresher ? :ambiguous : :adopt_remote
    when :local_contains_remote then remote_strictly_fresher || local_fresh.nil? ? :rebase_onto_remote : :publish
    else :ambiguous
    end
  end

  def initialize(git:, chdir:, local:, remote:, base: nil, rewritten_from: [])
    @git = git
    @chdir = chdir.to_s
    @local = local.to_s
    @remote = remote.to_s.strip.presence
    @base = base.to_s.strip.presence
    @rewritten_from = Array(rewritten_from).map { |sha| sha.to_s.strip }.reject(&:blank?)
  end

  def classify
    local_sha = rev_parse(@local)
    return result(:absent, local_sha: local_sha) if @remote.nil?
    return result(:identical, local_sha: local_sha) if local_sha == @remote
    return result(:rewrite, local_sha: local_sha) if @rewritten_from.include?(@remote)
    return result(:fast_forward, local_sha: local_sha) if ancestor?(@remote, local_sha)

    base_sha = @base && rev_parse(@base)
    local_fresh = base_sha ? ancestor?(base_sha, local_sha) : nil
    remote_fresh = base_sha ? ancestor?(base_sha, @remote) : nil
    return result(:remote_ahead, local_sha: local_sha, base_sha: base_sha, local_fresh: local_fresh, remote_fresh: remote_fresh) if ancestor?(local_sha, @remote)

    content = patch_content(local_sha, base_sha)
    relation =
      if same_tree?(local_sha, @remote) || (content[:local_preserved] && content[:remote_preserved])
        :equivalent
      elsif content[:local_preserved]
        :remote_contains_local
      elsif content[:remote_preserved]
        :local_contains_remote
      else
        :diverged
      end
    result(relation, local_sha: local_sha, base_sha: base_sha, local_fresh: local_fresh, remote_fresh: remote_fresh, evidence: content[:evidence])
  rescue GitRunner::GitError => e
    Result.new(
      relation: :unknown, outcome: :ambiguous, local_sha: nil, remote_sha: @remote, base_sha: nil,
      local_fresh: nil, remote_fresh: nil,
      evidence: { "error" => e.message.to_s.lines.first.to_s.strip.first(300) }
    )
  end

  private

  def result(relation, local_sha:, base_sha: nil, local_fresh: nil, remote_fresh: nil, evidence: {})
    Result.new(
      relation: relation,
      outcome: self.class.outcome_for(relation, local_fresh: local_fresh, remote_fresh: remote_fresh),
      local_sha: local_sha, remote_sha: @remote, base_sha: base_sha,
      local_fresh: local_fresh, remote_fresh: remote_fresh, evidence: evidence
    )
  end

  # Each side's own content: commits the other side lacks, minus commits
  # already on the base (reachable from it, or patch-equivalent to it).
  def patch_content(local_sha, base_sha)
    local_only = cherry(@remote, local_sha)
    remote_only = cherry(local_sha, @remote)
    local_content = off_base(local_only, local_sha, base_sha)
    remote_content = off_base(remote_only, @remote, base_sha)

    local_merges = unmatched_merges(@remote, local_sha, base_sha)
    remote_merges = unmatched_merges(local_sha, @remote, base_sha)

    {
      local_preserved: local_merges.empty? && local_content.values.all?("-"),
      remote_preserved: remote_merges.empty? && remote_content.values.all?("-"),
      evidence: {
        "local_only_commits" => local_content.size,
        "local_unmatched_commits" => local_content.count { |_, mark| mark == "+" } + local_merges.size,
        "remote_only_commits" => remote_content.size,
        "remote_unmatched_commits" => remote_content.count { |_, mark| mark == "+" } + remote_merges.size
      }
    }
  end

  # Keeps only the commits that are neither reachable from the base nor
  # patch-equivalent to a base commit: `git cherry base head` lists exactly
  # base..head and marks the base-equivalent ones "-".
  def off_base(commits, head, base_sha)
    return commits unless base_sha

    vs_base = cherry(base_sha, head)
    commits.select { |sha, _| vs_base[sha] == "+" }
  end

  # `git cherry upstream head`: one line per non-merge commit in
  # upstream..head, "-" when upstream has a patch-equivalent commit.
  def cherry(upstream, head)
    run("cherry", upstream, head).each_line.filter_map do |line|
      mark, sha = line.strip.split(/\s+/, 3)
      [ sha, mark ] if sha.present? && mark.in?(%w[+ -])
    end.to_h
  end

  def unmatched_merges(other, head, base_sha)
    args = [ "rev-list", "--merges", head, "^#{other}" ]
    args << "^#{base_sha}" if base_sha
    run(*args).split.reject(&:blank?)
  end

  def same_tree?(left, right)
    run("rev-parse", "--verify", "#{left}^{tree}").strip == run("rev-parse", "--verify", "#{right}^{tree}").strip
  end

  def ancestor?(ancestor, descendant)
    @git.run("merge-base", "--is-ancestor", ancestor, descendant, chdir: @chdir)
    true
  rescue GitRunner::GitError => e
    # Exit 1 is "not an ancestor"; anything else (an unknown object) is a
    # real failure the caller must not read as an answer.
    raise if e.exit_status.to_i > 1

    false
  end

  def rev_parse(ref)
    run("rev-parse", "--verify", "#{ref}^{commit}").strip
  end

  def run(*args)
    @git.run(*args, chdir: @chdir).to_s
  end
end
