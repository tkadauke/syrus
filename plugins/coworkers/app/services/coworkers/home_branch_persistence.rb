class Coworkers::HomeBranchPersistence
  include Syrus::Plugin::ChatTurnFinalizer

  Conflict = Class.new(StandardError)

  def self.after_chat_turn(chat_session:, **)
    link = Coworkers::Chat.includes(:coworker).find_by(chat_session_id: chat_session.id)
    return unless link

    new(chat_session, link.coworker).persist!
  end

  def initialize(chat_session, coworker, git: GitRunner.new)
    @chat_session = chat_session
    @coworker = coworker
    @git = git
  end

  def persist!
    repository = @coworker.workspace_repository
    path = ChatWorkspace.repo_path_for(@chat_session, repository)
    branch = "coworkers/#{@coworker.handle}"

    if ChatWorkspace.rebase_in_progress?(path)
      continue_rebase!(path)
      push!(repository, path, branch)
      return
    end

    commit_changes!(path) if ChatWorkspace.uncommitted_changes?(path)
    return unless unpublished_commits?(path, branch)

    push!(repository, path, branch)
  rescue GitRunner::GitError => e
    raise unless non_fast_forward?(e)

    reconcile_and_push!(repository, path, branch)
  end

  private

  def commit_changes!(path)
    @git.configure_author(Coworkers::GitIdentity.new(name: @coworker.name, handle: @coworker.handle), chdir: path.to_s)
    @git.run("add", "--all", chdir: path.to_s)
    @git.run("commit", "-m", "Update @#{@coworker.handle}'s workspace", "--no-verify", chdir: path.to_s)
  end

  def unpublished_commits?(path, branch)
    @git.run("rev-list", "--count", "origin/#{branch}..HEAD", chdir: path.to_s).strip.to_i.positive?
  end

  def push!(repository, path, branch)
    url = repository.authenticated_url(user: @chat_session.user)
    @git.run(
      "push", url,
      "HEAD:refs/heads/#{branch}", chdir: path.to_s,
      env: { "GIT_TERMINAL_PROMPT" => "0" }
    )
    refresh_remote_branch!(url, path, branch)
  end

  def reconcile_and_push!(repository, path, branch)
    url = repository.authenticated_url(user: @chat_session.user)
    refresh_remote_branch!(url, path, branch)
    begin
      @git.run("rebase", "origin/#{branch}", chdir: path.to_s)
    rescue GitRunner::GitError => e
      raise Conflict,
        "the coworker home branch changed remotely and conflicts remain in #{conflict_paths(path)}; " \
        "edit those files on the next turn, then Syrus will continue and push the preserved local commits (#{e.message})"
    end
    push!(repository, path, branch)
  end

  def refresh_remote_branch!(url, path, branch)
    refspec = "+refs/heads/#{branch}:refs/remotes/origin/#{branch}"
    @git.run("fetch", url, refspec, "--prune", chdir: path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" })
  end

  def continue_rebase!(path)
    unresolved = conflict_paths(path)
    if unresolved_conflict_markers?(path, unresolved)
      raise Conflict,
        "workspace conflicts remain in #{unresolved}; edit those files, then Syrus will continue the rebase and push"
    end

    @git.run("add", "--all", chdir: path.to_s)
    @git.run("rebase", "--continue", chdir: path.to_s, env: { "GIT_EDITOR" => "true" })
  rescue GitRunner::GitError => e
    raise Conflict,
      "workspace conflict recovery still needs edits in #{conflict_paths(path)}; " \
      "the rebase and local commits remain available for the next turn (#{e.message})"
  end

  def conflict_paths(path)
    @git.run("diff", "--name-only", "--diff-filter=U", chdir: path.to_s).lines.map(&:strip).reject(&:blank?).join(", ").presence || "the workspace"
  rescue GitRunner::GitError
    "the workspace"
  end

  def unresolved_conflict_markers?(path, paths)
    return true if paths == "the workspace"

    paths.split(", ").any? do |relative|
      file = Pathname.new(path).join(relative)
      file.file? && File.binread(file).match?(/^(?:<<<<<<<|=======|>>>>>>>)(?: |$)/n)
    rescue ArgumentError, Encoding::CompatibilityError
      true
    end
  end

  def non_fast_forward?(error)
    error.message.match?(/non-fast-forward|fetch first|rejected.*behind/i)
  end
end
