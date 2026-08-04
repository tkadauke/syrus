require "fileutils"

class BranchPatchPresence
  def self.no_unique_commits?(job:, pr:, client:, git: nil)
    new(job: job, pr: pr, client: client, git: git).no_unique_commits?
  end

  def initialize(job:, pr:, client:, git: nil)
    @job = job
    @pr = pr
    @client = client
    @git = git || GitRunner.new
    @env = { "GIT_TERMINAL_PROMPT" => "0" }
  end

  def no_unique_commits?
    return false if branch_name.blank?
    return false if base_ref.blank?

    clone_base_branch
    fetch_branch_head
    no_unique_patches?
  rescue StandardError => e
    Rails.logger.info("[BranchPatchPresence] #{@job.slug} check failed: #{e.class}: #{e.message}")
    false
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

  def no_unique_patches?
    output = @git.run("cherry", "-v", "origin/#{base_ref}", feature_ref, chdir: clone_path.to_s)
    output.each_line.none? { |line| line.start_with?("+") }
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
