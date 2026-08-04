require "fileutils"

# Maintains a per-repository bare clone at
# $SYRUS_DATA_ROOT/clones/<repo_id>.git.
#
# On first call, `sync!` clones the repository with `--bare`. On
# subsequent calls it runs `git fetch --prune` to advance all
# remote-tracking refs. Once synced, `commits_behind(head_sha:,
# base_sha:)` runs `git rev-list --count` to compute how many commits
# base has that head does not — i.e., how far behind a PR branch is.
#
# The bare clone is a background maintenance artifact. Callers must
# rescue errors from both `sync!` and `commits_behind` and treat
# nil as "not yet computed" rather than a hard failure.
class RepositoryBareClone
  def initialize(repository, git: nil)
    @repository = repository
    @git = git || GitRunner.new
    @env = { "GIT_TERMINAL_PROMPT" => "0" }
  end

  def self.path_for(repository)
    WorkflowWorkspace.data_root.join("clones", "#{repository.id}.git")
  end

  def path
    @path ||= self.class.path_for(@repository)
  end

  # Initializes the bare clone if absent, or fetches updates if present.
  # Authenticates via `user` so private repos work.
  def sync!(user:)
    if path.exist?
      fetch!(user: user)
    else
      clone!(user: user)
    end
  end

  # Returns how many commits `base_sha` has that `head_sha` does not
  # (i.e., how many commits a PR is behind its base branch).
  # Returns nil if either SHA is blank or not reachable.
  def commits_behind(head_sha:, base_sha:)
    return nil if head_sha.blank? || base_sha.blank?

    count = @git.run(
      "rev-list", "--count",
      "#{head_sha}..#{base_sha}",
      chdir: path.to_s
    ).strip.to_i

    count
  rescue GitRunner::GitError
    nil
  end

  private

  def clone!(user:)
    FileUtils.mkdir_p(path.dirname)
    GithubAuthenticatedGit.run(repository: @repository, user: user, git: @git, operation_type: "git_bare_clone") do |url|
      @git.run(
        "clone", "--bare", "--no-tags",
        url, path.to_s,
        env: @env
      )
    end
  end

  def fetch!(user:)
    GithubAuthenticatedGit.run(repository: @repository, user: user, git: @git, operation_type: "git_bare_fetch") do |url|
      @git.run(
        "fetch", "--prune",
        url,
        "+refs/heads/*:refs/heads/*",
        chdir: path.to_s,
        env: @env
      )
    end
  end

end
