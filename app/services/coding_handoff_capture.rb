class CodingHandoffCapture
  class CaptureError < StandardError; end

  def self.capture!(...) = new(...).capture!

  def initialize(chat_session:, repository:, user:, source_branch:, handoff_branch:, git: GitRunner.new(env: { "GIT_TERMINAL_PROMPT" => "0" }))
    @chat_session = chat_session
    @repository = repository
    @user = user
    @source_branch = source_branch.to_s
    @handoff_branch = handoff_branch.to_s
    @git = git
  end

  def capture!
    raise CaptureError, "coding checkout not found for #{repository.slug}" unless checkout_path.join(".git").exist?
    raise CaptureError, "coding checkout is on #{current_branch.inspect}, expected #{source_branch.inspect}" unless current_branch == source_branch
    raise CaptureError, "coding checkout has uncommitted changes; commit them before submitting" if dirty_worktree?

    fetch_default_branch!

    head_sha = rev_parse("HEAD")
    base_sha = rev_parse(default_ref)
    changed_files = diff_files
    raise CaptureError, "coding handoff branch has no committed changes against #{repository.default_branch}" if changed_files.empty?

    publish_snapshot!(head_sha)

    {
      "source_branch" => source_branch,
      "handoff_branch" => handoff_branch,
      "head_sha" => head_sha,
      "base_sha" => base_sha,
      "default_branch" => repository.default_branch,
      "changed_files" => changed_files,
      "captured_at" => Time.current.iso8601,
      "chat_session_id" => chat_session.id
    }
  end

  private

  attr_reader :chat_session, :repository, :user, :source_branch, :handoff_branch, :git

  def checkout_path
    @checkout_path ||= ChatWorkspace.repo_path_for(chat_session, repository)
  end

  def current_branch
    @current_branch ||= git.run("branch", "--show-current", chdir: checkout_path.to_s).strip
  end

  def dirty_worktree?
    git.run("status", "--porcelain", chdir: checkout_path.to_s).strip.present?
  end

  def fetch_default_branch!
    authenticated_git("git_coding_handoff_fetch") do |url|
      git.run(
        "fetch",
        url,
        "+refs/heads/#{repository.default_branch}:refs/remotes/origin/#{repository.default_branch}",
        "--prune",
        chdir: checkout_path.to_s
      )
    end
  end

  def default_ref
    "refs/remotes/origin/#{repository.default_branch}"
  end

  def rev_parse(ref)
    git.run("rev-parse", ref, chdir: checkout_path.to_s).strip
  end

  def diff_files
    git.run("diff", "--name-only", "#{default_ref}...HEAD", chdir: checkout_path.to_s)
      .lines
      .map(&:strip)
      .reject(&:empty?)
  end

  def publish_snapshot!(head_sha)
    remote_sha = remote_branch_sha
    if remote_sha.present?
      raise CaptureError, "coding handoff branch #{handoff_branch} already exists at #{remote_sha}, expected #{head_sha}" unless remote_sha == head_sha

      return
    end

    authenticated_git("git_coding_handoff_push") do |url|
      git.run("push", url, "HEAD:refs/heads/#{handoff_branch}", chdir: checkout_path.to_s)
    end
    actual_sha = remote_branch_sha
    raise CaptureError, "coding handoff branch #{handoff_branch} was not published" if actual_sha.blank?
    raise CaptureError, "coding handoff branch #{handoff_branch} published #{actual_sha}, expected #{head_sha}" unless actual_sha == head_sha
  end

  def remote_branch_sha
    output = authenticated_git("git_coding_handoff_ls_remote") do |url|
      git.run("ls-remote", "--heads", url, "refs/heads/#{handoff_branch}", chdir: checkout_path.to_s)
    end.strip
    output.split(/\s+/).first.presence
  end

  def authenticated_url
    @authenticated_url ||= repository.authenticated_url(user: user)
  end

  def authenticated_git(operation_type, &block)
    @authenticated_url = nil
    GithubAuthenticatedGit.run(repository: repository, user: user, git: git, operation_type: operation_type, &block)
  end
end
