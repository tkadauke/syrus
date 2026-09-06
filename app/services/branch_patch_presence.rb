require "fileutils"

# What a closed PR's branch still holds relative to its base -- three
# outcomes, not two.
#
# `git cherry` already distinguishes them and the old boolean threw the
# distinction away: a branch whose commits all have equivalents on the base
# (they LANDED, typically via a merge train or a cherry-pick) read the same as
# a branch that never had a commit at all (the agent produced nothing). Both
# closed the Job as `no_changes`, so landed work was filed as "this Job did
# nothing" -- see JOB-4346.
class BranchPatchPresence
  # The branch has no commits the base lacks, and none that the base has an
  # equivalent of either: there was never anything here.
  NO_COMMITS = :no_commits
  # Every commit on the branch has an equivalent on the base. The work landed.
  ALL_LANDED = :all_landed
  # Real, unmerged commits.
  HAS_UNIQUE = :has_unique

  def self.classify(job:, pr:, client:, git: nil)
    new(job: job, pr: pr, client: client, git: git).classify
  end

  def self.no_unique_commits?(job:, pr:, client:, git: nil)
    classify(job: job, pr: pr, client: client, git: git) != HAS_UNIQUE
  end

  def initialize(job:, pr:, client:, git: nil)
    @job = job
    @pr = pr
    @client = client
    @git = git || GitRunner.new
    @env = { "GIT_TERMINAL_PROMPT" => "0" }
  end

  # Unknowable reads as HAS_UNIQUE: without evidence, assume there is
  # unmerged work, which is the outcome that changes the least.
  def classify
    return HAS_UNIQUE if branch_name.blank?
    return HAS_UNIQUE if base_ref.blank?

    clone_base_branch
    fetch_branch_head
    cherry_classification
  rescue StandardError => e
    Rails.logger.info("[BranchPatchPresence] #{@job.slug} check failed: #{e.class}: #{e.message}")
    HAS_UNIQUE
  ensure
    cleanup_clone
  end

  private

  def clone_path
    @clone_path ||= WorkflowWorkspace.data_root.join(
      "closed-pr-checks",
      "#{@job.id}-#{SecureRandom.hex(8)}"
    )
  end

  def authenticated_url
    @job.repository.authenticated_push_url(@client.access_token)
  end

  def base_ref
    @base_ref ||= MergeabilityRecorder.base_ref(@pr) || @job.repository.default_branch
  end

  def branch_name
    @job.branch_name
  end

  def clone_base_branch
    FileUtils.mkdir_p(clone_path.dirname)
    authenticated_git("git_closed_pr_clone") do |url|
      @git.run(
        "clone",
        "--branch", base_ref,
        "--no-tags", url, clone_path.to_s,
        env: @env
      )
    end
  end

  def fetch_branch_head
    authenticated_git("git_closed_pr_fetch") do |url|
      @git.run(
        "fetch", url,
        "refs/heads/#{branch_name}:#{feature_ref}",
        chdir: clone_path.to_s,
        env: @env
      )
    end
  end

  # `git cherry` prints one line per commit on the branch: `+` when the base
  # has no equivalent, `-` when it does. No lines at all means the branch is
  # not ahead of the base by even one commit.
  def cherry_classification
    lines = @git.run("cherry", "-v", "origin/#{base_ref}", feature_ref, chdir: clone_path.to_s)
                .each_line.map(&:strip).reject(&:empty?)

    return HAS_UNIQUE if lines.any? { |line| line.start_with?("+") }
    return ALL_LANDED if lines.any? { |line| line.start_with?("-") }

    NO_COMMITS
  end

  def feature_ref
    "refs/remotes/syrus-closed-pr/head"
  end

  def cleanup_clone
    FileUtils.rm_rf(clone_path) if clone_path&.exist?
  end

  def authenticated_git(operation_type, &block)
    GithubAuthenticatedGit.run(repository: @job.repository, user: @job.user, git: @git, operation_type: operation_type, &block)
  end
end
