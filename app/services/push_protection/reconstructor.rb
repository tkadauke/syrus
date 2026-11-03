module PushProtection
  # Rebuilds the authoritative single commit from three inputs only: the clean
  # anchor, the repaired tree, and harness-controlled metadata. Because every
  # input is fixed, the result is idempotent -- if the agent already produced
  # an equivalent amend the SHA is unchanged; if it did anything else
  # semantically equal, the harness still lands on the same commit.
  module Reconstructor
    module_function

    def commit_tree!(repo, tree:, anchor:, metadata:)
      repo.out("commit-tree", tree, "-p", anchor, "-m", metadata.message, env: metadata.env)
    end

    # Returns the new HEAD sha; moves the working branch only when needed.
    def call(repo, anchor:, metadata:)
      sha = commit_tree!(repo, tree: repo.tree("HEAD"), anchor: anchor, metadata: metadata)
      repo.run("reset", "--hard", sha) unless sha == repo.head
      sha
    end
  end
end
