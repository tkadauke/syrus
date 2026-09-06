class ClosedPullRequestResolution
  def self.reason(job:, pr:, client:, git: nil)
    new(job: job, pr: pr, client: client, git: git).reason
  end

  def initialize(job:, pr:, client:, git: nil)
    @job = job
    @pr = pr
    @client = client
    @git = git
  end

  def reason
    return "pr_merged" if merged?

    case branch_state
    # GitHub never marked the PR merged, but every commit on the branch has an
    # equivalent on the base -- a merge train landed it, or someone
    # cherry-picked it. That is a landing, and calling it "no changes" files
    # real work as work that never happened.
    when BranchPatchPresence::ALL_LANDED then "pr_merged"
    # Nothing on the branch at all: the agent genuinely produced no changes.
    when BranchPatchPresence::NO_COMMITS then "no_changes"
    else "pr_closed"
    end
  end

  private

  def merged?
    @pr.respond_to?(:merged) && @pr.merged
  end

  def branch_state
    BranchPatchPresence.classify(job: @job, pr: @pr, client: @client, git: @git)
  end
end
