module PushProtection
  # Builds the repair candidate: the entire rejected range collapsed into one
  # commit directly atop the clean anchor, with the rejected tree intact, so
  # the agent only has to make the semantic content repair.
  #
  # Also captures the baseline the TopologyValidator later compares against
  # (refs, remotes, repository config, gitlinks) and preserves the rejected
  # history outside GitHub as a bundle.
  class Candidate
    Result = Data.define(:sha, :rejected_head, :rejected_range, :bundle_path, :baseline, :metadata)

    def initialize(repo:, branch:, anchor:, bundle_dir:)
      @repo = repo
      @branch = branch
      @anchor = anchor
      @bundle_dir = Pathname.new(bundle_dir)
    end

    def prepare!
      rejected_head = repo.head
      range = repo.range(anchor, rejected_head)
      raise ArgumentError, "rejected range is empty" if range.empty?

      bundle_path = preserve_rejected!(rejected_head)
      metadata = Metadata.capture(repo, rejected_head)
      sha = Reconstructor.commit_tree!(repo, tree: repo.tree(rejected_head), anchor: anchor, metadata: metadata)
      repo.run("reset", "--hard", sha)
      Result.new(sha: sha, rejected_head: rejected_head, rejected_range: range,
                 bundle_path: bundle_path.to_s, baseline: baseline_for(sha), metadata: metadata.to_h)
    end

    private

    attr_reader :repo, :branch, :anchor, :bundle_dir

    def preserve_rejected!(rejected_head)
      FileUtils.mkdir_p(bundle_dir)
      path = bundle_dir.join("rejected-#{rejected_head}.bundle")
      repo.run("bundle", "create", path.to_s, "HEAD", "^#{anchor}") unless path.exist?
      path
    end

    # Everything the agent is not allowed to change, captured after the
    # candidate is checked out.
    def baseline_for(sha)
      {
        "candidate_sha" => sha,
        "candidate_tree" => repo.tree(sha),
        "refs" => repo.refs_except(branch),
        "remotes" => repo.remotes,
        "config" => repo.config_text,
        "gitlinks" => repo.gitlinks(sha),
        "gitmodules" => repo.gitmodules(sha)
      }
    end
  end
end
