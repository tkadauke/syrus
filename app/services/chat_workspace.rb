require "fileutils"

# Persistent per-ChatSession workspace used by top-level chat inspection.
# Unlike WorkflowWorkspace, this workspace is long-lived and is not reset
# between turns. Repositories are cloned lazily under the session root.
class ChatWorkspace
  CLONE_DEPTH = 50
  EXCLUDE_ENTRY = ".syrus/".freeze

  def self.data_root
    Pathname.new(ENV["SYRUS_DATA_ROOT"] || File.expand_path("~/.syrus"))
  end

  def self.path_for(chat_session)
    return Pathname.new(chat_session.workspace_path) if chat_session.workspace_path.present?

    data_root.join("chat-workspaces", chat_session.id.to_s)
  end

  def self.repo_path_for(chat_session, repository)
    path_for(chat_session).join("repositories", repository.owner, repository.name)
  end

  def self.ensure_root!(chat_session)
    new(chat_session).ensure_root!
  end

  def self.attach_repository!(chat_session, repository)
    new(chat_session).attach_repository!(repository)
  end

  def self.refresh!(chat_session, repository)
    new(chat_session).refresh!(repository)
  end

  def self.reset!(chat_session)
    new(chat_session).reset!
  end

  def self.destroy!(chat_session)
    FileUtils.rm_rf(path_for(chat_session).to_s)
  end

  def self.prune_idle!(older_than:)
    cutoff = older_than.ago
    n = 0

    ChatSession.where.not(workspace_path: nil)
               .where("COALESCE(last_message_at, updated_at) < ?", cutoff)
               .find_each do |chat_session|
      destroy!(chat_session)
      chat_session.update_columns(workspace_path: nil, updated_at: Time.current)
      n += 1
    end

    n
  end

  def initialize(chat_session, git: nil)
    @chat_session = chat_session
    @git = git || GitRunner.new
    @env = { "GIT_TERMINAL_PROMPT" => "0" }
  end

  def ensure_root!
    path = self.class.path_for(@chat_session)
    FileUtils.mkdir_p(path.to_s)
    persist_workspace_path!(path)
    path
  end

  def attach_repository!(repository)
    ensure_root!
    path = self.class.repo_path_for(@chat_session, repository)

    if path.join(".git").directory?
      fast_forward!(repository, path)
    else
      clone!(repository, path)
    end

    @chat_session.chat_attachments.find_or_create_by!(attachable: repository)
    path
  end

  def refresh!(repository)
    attach_repository!(repository)
  end

  def reset!
    self.class.destroy!(@chat_session)
    ensure_root!
  end

  private

  def clone!(repository, path)
    FileUtils.mkdir_p(path.dirname.to_s)
    @git.run(
      "clone", "--depth", CLONE_DEPTH.to_s,
      "--branch", repository.default_branch,
      "--no-tags", authenticated_url(repository), path.to_s,
      env: @env
    )
    @git.run("remote", "set-url", "origin", repository.remote_url, chdir: path.to_s)
    GitInfoExclude.ensure_entry!(path, EXCLUDE_ENTRY)
  end

  def fast_forward!(repository, path)
    @git.run("fetch", "origin", repository.default_branch, "--prune", chdir: path.to_s, env: @env)
    @git.run("checkout", repository.default_branch, chdir: path.to_s)
    @git.run("merge", "--ff-only", "origin/#{repository.default_branch}", chdir: path.to_s)
    GitInfoExclude.ensure_entry!(path, EXCLUDE_ENTRY)
  end

  def persist_workspace_path!(path)
    return if @chat_session.workspace_path == path.to_s

    @chat_session.update_columns(workspace_path: path.to_s, updated_at: Time.current)
  end

  def authenticated_url(repository)
    token = GithubClient.for(repository: repository, user: repository.user).access_token
    repository.authenticated_push_url(token)
  end
end
