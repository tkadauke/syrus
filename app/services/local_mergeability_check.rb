require "fileutils"

class LocalMergeabilityCheck
  Result = Data.define(:state, :mergeable, :message, :head_sha, :base_sha, :base_ref) do
    def clean? = state == "clean"
    def conflict? = state == "conflict"
    def error? = state == "error"
    def skipped? = state == "skipped"
  end

  def initialize(job:, pr:, git: nil)
    @job = job
    @pr = pr
    @git = git || GitRunner.new
    @env = { "GIT_TERMINAL_PROMPT" => "0" }
  end

  def call
    return skipped("job has no branch") if @job.branch_name.blank?
    return skipped("PR has no base ref") if base_ref.blank?

    clone_base_branch
    fetch_and_checkout_feature_branch
    configure_git_author
    register_merge_drivers

    observed_base_sha = base_head_sha
    observed_head_sha = head_sha

    if rebase_succeeded?
      Result.new(
        state: "clean",
        mergeable: true,
        message: "local rebase preflight passed",
        head_sha: observed_head_sha,
        base_sha: observed_base_sha,
        base_ref: base_ref
      )
    else
      abort_rebase
      Result.new(
        state: "conflict",
        mergeable: false,
        message: "local rebase preflight found conflicts",
        head_sha: observed_head_sha,
        base_sha: observed_base_sha,
        base_ref: base_ref
      )
    end
  rescue StandardError => e
    abort_rebase
    Rails.logger.warn("[LocalMergeabilityCheck] #{@job.slug} failed: #{e.class}: #{e.message}")
    Result.new(
      state: "error",
      mergeable: nil,
      message: "#{e.class}: #{e.message}",
      head_sha: safe_head_sha,
      base_sha: safe_base_sha,
      base_ref: base_ref
    )
  ensure
    cleanup_clone
  end

  private

  def skipped(message)
    Result.new(
      state: "skipped",
      mergeable: nil,
      message: message,
      head_sha: pr_head_sha,
      base_sha: pr_base_sha,
      base_ref: base_ref
    )
  end

  def clone_path
    @clone_path ||= WorkflowWorkspace.data_root.join(
      "mergeability",
      "#{@job.id}-#{SecureRandom.hex(8)}"
    )
  end

  def authenticated_url
    @authenticated_url ||= @job.repository.authenticated_url(user: @job.user)
  end

  def base_ref
    @base_ref ||= MergeabilityRecorder.base_ref(@pr) || @job.effective_base_branch
  end

  def pr_head_sha
    MergeabilityRecorder.head_sha(@pr)
  end

  def pr_base_sha
    MergeabilityRecorder.base_sha(@pr)
  end

  def clone_base_branch
    FileUtils.mkdir_p(clone_path.dirname)
    authenticated_git("git_mergeability_clone") do |url|
      @git.run(
        "clone",
        "--branch", base_ref,
        "--no-tags", url, clone_path.to_s,
        env: @env
      )
    end
  end

  def fetch_and_checkout_feature_branch
    authenticated_git("git_mergeability_fetch") do |url|
      @git.run(
        "fetch", url,
        "refs/heads/#{@job.branch_name}:refs/heads/#{@job.branch_name}",
        chdir: clone_path.to_s,
        env: @env
      )
    end
    @git.run("checkout", @job.branch_name, chdir: clone_path.to_s)
  end

  def authenticated_git(operation_type, &block)
    @authenticated_url = nil
    GithubAuthenticatedGit.run(repository: @job.repository, user: @job.user, git: @git, operation_type: operation_type, &block)
  end

  def configure_git_author
    @git.configure_author(BotIdentity.for(@job), chdir: clone_path.to_s)
  end

  def register_merge_drivers
    attrs = clone_path.join(".gitattributes")
    return unless attrs.exist?

    names = attrs.each_line.flat_map { |line| line.scan(/merge=(\S+)/).flatten }.uniq
    names.each do |name|
      script = clone_path.join("bin", "merge-#{name}")
      next unless script.exist? && File.executable?(script)

      @git.run(
        "config", "merge.#{name}.driver",
        "#{script} %O %A %B",
        chdir: clone_path.to_s
      )
    end
  end

  def rebase_succeeded?
    @git.run("rebase", "origin/#{base_ref}", chdir: clone_path.to_s, env: @env)
    true
  rescue GitRunner::GitError
    false
  end

  def abort_rebase
    return unless clone_path.exist?

    @git.run("rebase", "--abort", chdir: clone_path.to_s)
  rescue StandardError
    nil
  end

  def cleanup_clone
    FileUtils.rm_rf(clone_path) if clone_path.exist?
  end

  def head_sha
    @git.run("rev-parse", "HEAD", chdir: clone_path.to_s).strip
  end

  def base_head_sha
    @git.run("rev-parse", "origin/#{base_ref}", chdir: clone_path.to_s).strip
  end

  def safe_head_sha
    return pr_head_sha unless clone_path.exist?

    head_sha
  rescue StandardError
    pr_head_sha
  end

  def safe_base_sha
    return pr_base_sha unless clone_path.exist?

    base_head_sha
  rescue StandardError
    pr_base_sha
  end
end
