require "fileutils"

# Attempts a non-interactive `git rebase origin/<base>` on the Job's
# branch. If it exits clean, force-push the result and skip the
# agentic rebase Run entirely. If conflicts remain, abort and signal
# the caller to fall back to the agent.
#
# Whatever merge drivers the target repo declares in `.gitattributes`
# get a chance to do their job — Syrus discovers them by convention
# (a `merge=NAME` reference paired with an executable `bin/merge-NAME`
# script in the clone) and registers them in the clone's `.git/config`
# before running rebase. No Ruby/Rails-specific knowledge in Syrus;
# the driver lives in (and is shipped by) the target repo.
class AutoRebase
  Result = Data.define(:succeeded, :reason, :note) do
    def succeeded?
      succeeded
    end

    def to_s
      [ reason, note ].compact.reject(&:empty?).join(" — ")
    end
  end

  def initialize(job, git: nil)
    @job = job
    @git = git || GitRunner.new
    @env = { "GIT_TERMINAL_PROMPT" => "0" }
  end

  def call
    return Result.new(false, "no_branch", nil) if @job.branch_name.blank?
    return Result.new(false, "no_repo", nil)   unless @job.repository

    # Clone the base branch (not shallow — rebase needs full history
    # to find merge-base). After clone, `origin/<base>` is set to the
    # current tip of the effective base branch, which is exactly what
    # we rebase onto. Then fetch + checkout the feature branch.
    clone_base_branch
    fetch_and_checkout_feature_branch
    configure_git_author

    register_merge_drivers

    pre_sha = head_sha

    if rebase_succeeded?
      post_sha = head_sha
      if pre_sha == post_sha
        Result.new(true, "rebased", "no-op (already up-to-date)")
      else
        force_push
        Result.new(true, "rebased", "advanced #{pre_sha[0, 7]} → #{post_sha[0, 7]}")
      end
    else
      abort_rebase
      Result.new(false, "conflict", nil)
    end
  rescue StandardError => e
    abort_rebase
    Rails.logger.warn("[AutoRebase] job #{@job.id} unexpected error: #{e.class}: #{e.message}")
    Result.new(false, "error", e.message)
  ensure
    cleanup_clone
  end

  private

  def clone_path
    @clone_path ||= WorkflowWorkspace.data_root.join("auto-rebase", @job.id.to_s)
  end

  def authenticated_url
    token = GithubClient.for(repository: @job.repository, user: @job.user).access_token
    @job.repository.authenticated_push_url(token)
  end

  def base_branch
    @job.effective_base_branch
  end

  # Full (non-shallow) clone on the effective base branch so that
  # `origin/<base>` is available as a remote tracking ref and
  # merge-base computation works across any history depth.
  def clone_base_branch
    FileUtils.mkdir_p(clone_path.dirname)
    @git.run(
      "clone", "--branch", base_branch,
      "--no-tags", authenticated_url, clone_path.to_s,
      env: @env
    )
  end

  # Fetch the feature branch from origin and check it out locally.
  def fetch_and_checkout_feature_branch
    @git.run(
      "fetch", authenticated_url,
      "refs/heads/#{@job.branch_name}:refs/heads/#{@job.branch_name}",
      chdir: clone_path.to_s, env: @env
    )
    @git.run("checkout", @job.branch_name, chdir: clone_path.to_s)
  end

  def cleanup_clone
    FileUtils.rm_rf(clone_path)
  end

  # Discover and register custom merge drivers the target repo
  # declares. Convention:
  #
  #   .gitattributes:    db/schema.rb merge=ruby_schema
  #   repo file:         bin/merge-ruby_schema  (executable)
  #
  # Each `merge=NAME` reference becomes
  #   git config merge.NAME.driver "<absolute-path-to-script> %O %A %B"
  # in the clone's .git/config so git uses the driver during rebase.
  #
  # Idempotent. Repos without `.gitattributes` or without matching
  # scripts are silently skipped — Syrus has no opinion on whether
  # a target repo "should" have merge drivers; it just respects
  # what's declared.
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

  def configure_git_author
    identity = BotIdentity.for(@job)
    @git.run("config", "--local", "user.name", identity.git_name, chdir: clone_path.to_s)
    @git.run("config", "--local", "user.email", identity.git_email, chdir: clone_path.to_s)
  end

  def rebase_succeeded?
    @git.run(
      "rebase", "origin/#{base_branch}",
      chdir: clone_path.to_s, env: @env
    )
    true
  rescue GitRunner::GitError
    false
  end

  def abort_rebase
    return unless clone_path.exist?
    @git.run("rebase", "--abort", chdir: clone_path.to_s) rescue nil
  end

  def force_push
    @git.run("push", "--force", authenticated_url,
             "HEAD:refs/heads/#{@job.branch_name}",
             chdir: clone_path.to_s, env: @env)
  end

  def head_sha
    @git.run("rev-parse", "HEAD", chdir: clone_path.to_s).strip
  end
end
