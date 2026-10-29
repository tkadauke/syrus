require "fileutils"
require "tmpdir"

class Coworkers::ChatWorkspaceLifecycle
  include Syrus::Plugin::ChatWorkspaceLifecycle
  MAX_PUSH_ATTEMPTS = 3

  class << self
    def applies_to?(chat_session:)
      chat_session.respond_to?(:coworker) && chat_session.coworker.kind == "coworker"
    end

    def prepare!(chat_session:)
      new(chat_session).prepare!
    end

    def finalize!(chat_session:)
      new(chat_session).finalize!
    end
  end

  def initialize(chat_session, git: GitRunner.new, remote_url: nil, repository: nil)
    @chat = chat_session
    @coworker = chat_session.coworker
    @repository = repository || workspace_repository
    @git = git
    @remote_url = remote_url || @repository.authenticated_url(user: @coworker.owner_user)
    @env = { "GIT_TERMINAL_PROMPT" => "0" }
  end

  def prepare!
    ensure_chat_branch!
    ChatWorkspace.ensure_root!(@chat)
    path = checkout_path
    unless path.join(".git").directory?
      FileUtils.rm_rf(path.to_s)
      FileUtils.mkdir_p(path.dirname.to_s)
      clone_branch!(chat_branch, path.to_s)
      @chat.chat_attachments.find_or_create_by!(attachable: @repository)
    end
    @git.configure_author(identity, chdir: path.to_s)
    path
  end

  def finalize!
    path = checkout_path
    return unless path.join(".git").directory?
    conflicts = unmerged_files(path)
    return post_conflict!(files: conflicts, detail: "Resolve the existing Git index conflicts before the workspace can merge.") if conflicts.any?

    commit_turn!(path)
    push_chat_branch!(path)
    merge_into_home!(chat_branch)
  end

  # Background runs share the exact home-branch merge/retry/conflict path used
  # at chat turn end. Their immutable run ref preserves the completed work when
  # a concurrent chat changed the home branch incompatibly.
  def finalize_background!(path:, workflow:)
    path = Pathname(path)
    return :unavailable unless path.join(".git").directory?

    source_branch = "coworkers/run/#{@coworker.id}-#{workflow.id}"
    @git.configure_author(identity, chdir: path.to_s)
    if @git.run("status", "--porcelain", chdir: path.to_s).present?
      @git.run("add", "--all", chdir: path.to_s)
      @git.run("commit", "-m", "Update @#{@coworker.handle} from background run", chdir: path.to_s)
    end
    push_guard.allow!(source_branch)
    @git.run("push", @remote_url, "HEAD:refs/heads/#{source_branch}", chdir: path.to_s, env: @env)
    merge_into_home!(source_branch, conflict_checkout: path)
  end

  private

  def home_branch = "coworkers/#{@coworker.handle}"
  def chat_branch = "coworkers/chat/#{@coworker.id}-#{@chat.id}"
  def identity = Coworkers::GitIdentity.new(name: @coworker.name, handle: @coworker.handle)
  def push_guard = (@push_guard ||= Coworkers::PushGuard.new(coworker: @coworker))
  def checkout_path = ChatWorkspace.repo_path_for(@chat, @repository)

  def workspace_repository
    match = @coworker.workspace_repo.match(%r{github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?\z}i)
    raise ActiveRecord::RecordNotFound, "coworker workspace repository is not registered" unless match

    Repository.where("LOWER(owner) = ? AND LOWER(name) = ?", match[1].downcase, match[2].downcase).first!
  end

  def ensure_chat_branch!
    return if @git.run("ls-remote", "--heads", @remote_url, "refs/heads/#{chat_branch}", env: @env).present?

    Dir.mktmpdir("syrus-coworker-chat-") do |dir|
      clone_branch!(home_branch, dir)
      @git.run("switch", "-c", chat_branch, chdir: dir)
      push_guard.allow!(chat_branch)
      @git.run("push", @remote_url, "HEAD:refs/heads/#{chat_branch}", chdir: dir, env: @env)
    end
  rescue GitRunner::GitError
    # Another worker may have created the immutable chat ref concurrently.
    raise unless @git.run("ls-remote", "--heads", @remote_url, "refs/heads/#{chat_branch}", env: @env).present?
  end

  def commit_turn!(path)
    return if @git.run("status", "--porcelain", chdir: path.to_s).blank?

    @git.configure_author(identity, chdir: path.to_s)
    @git.run("add", "--all", chdir: path.to_s)
    @git.run("commit", "-m", "Update @#{@coworker.handle} from chat #{@chat.id}", chdir: path.to_s)
  end

  def push_chat_branch!(path)
    push_guard.allow!(chat_branch)
    @git.run("push", @remote_url, "HEAD:refs/heads/#{chat_branch}", chdir: path.to_s, env: @env)
  end

  def merge_into_home!(source_branch, conflict_checkout: checkout_path)
    MAX_PUSH_ATTEMPTS.times do |attempt|
      outcome = merge_once(source_branch, conflict_checkout:)
      return outcome unless outcome == :retry
      raise GitRunner::GitError.new([ "push", home_branch ], 1, "home branch kept moving") if attempt == MAX_PUSH_ATTEMPTS - 1
    end
  end

  def merge_once(source_branch, conflict_checkout:)
    Dir.mktmpdir("syrus-coworker-merge-") do |dir|
      clone_branch!(home_branch, dir)
      @git.configure_author(identity, chdir: dir)
      @git.run("fetch", @remote_url, "refs/heads/#{source_branch}:refs/remotes/origin/coworker-source", chdir: dir, env: @env)
      merge = @git.capture("merge", "--no-edit", "origin/coworker-source", chdir: dir, env: @env)
      return report_conflict!(dir, merge, source_branch:, conflict_checkout:) unless merge.success?

      @git.run("push", @remote_url, "HEAD:refs/heads/#{push_guard.allow!(home_branch)}", chdir: dir, env: @env)
      :merged
    rescue GitRunner::GitError => error
      raise unless error.output.match?(/non-fast-forward|fetch first|failed to push some refs/i)
      :retry
    end
  end

  def report_conflict!(merge_path, merge, source_branch:, conflict_checkout:)
    files = unmerged_files(merge_path)
    leave_conflict_in_checkout!(conflict_checkout)
    conflict_ref = snapshot_background_conflict!(conflict_checkout, source_branch) if background_run_branch?(source_branch)
    post_conflict!(files: files, detail: merge.stderr.to_s.last(500), source_branch:, ref: conflict_ref)
  end

  def post_conflict!(files:, detail:, source_branch: chat_branch, ref: nil)
    links = files.map do |file|
      query = { path: file, repository_id: @repository.id, ref: ref }.compact
      "/api/v1/app/chats/#{@chat.id}/source_file/raw?#{query.to_query}"
    end
    linked_files = files.zip(links).map { |file, link| "- [#{markdown_link_label(file)}](#{link})" }.join("\n")
    @chat.messages.create!(
      role: "system",
      content: {
        "text" => I18n.t("api.coworkers.workspace_conflict", branch: source_branch, files: linked_files),
        "body_format" => "markdown",
        "prominent" => true,
        "system_label" => I18n.t("api.coworkers.workspace_conflict_label"),
        "system_tone" => "warning",
        "coworker_workspace_conflict" => { "branch" => source_branch, "ref" => ref, "files" => files, "links" => links,
                                             "detail" => detail }
      }
    )
    :conflict
  end

  def unmerged_files(path)
    @git.run("diff", "--name-only", "--diff-filter=U", chdir: path.to_s).lines.map(&:strip).reject(&:blank?)
  end

  def markdown_link_label(value)
    value.gsub(/[\\\[\]]/) { |character| "\\#{character}" }
  end

  def leave_conflict_in_checkout!(path)
    @git.run("fetch", @remote_url, "refs/heads/#{home_branch}:refs/remotes/origin/coworker-home", chdir: path.to_s, env: @env)
    @git.capture("merge", "--no-edit", "origin/coworker-home", chdir: path.to_s, env: @env)
  end

  def background_run_branch?(branch)
    branch.start_with?("coworkers/run/")
  end

  def snapshot_background_conflict!(path, source_branch)
    @git.run("add", "--all", chdir: path.to_s)
    @git.run("commit", "-m", "Preserve @#{@coworker.handle} background run conflict", chdir: path.to_s)
    @git.run("push", @remote_url, "HEAD:refs/heads/#{push_guard.allow!(source_branch)}", chdir: path.to_s, env: @env)
    @git.run("rev-parse", "HEAD", chdir: path.to_s).strip
  end

  def clone_branch!(branch, destination)
    @git.run("clone", "--branch", branch, "--no-tags", @remote_url, destination, env: @env)
    # Never leave the authenticated transport URL in a checkout exposed to the
    # coworker's shell. Lifecycle operations pass it explicitly when needed.
    @git.run("remote", "set-url", "origin", @repository.remote_url, chdir: destination)
  end
end
