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

    workspace_root_for_id(chat_session.id)
  end

  def self.workspace_root_for_id(chat_session_id)
    data_root.join("chat-workspaces", chat_session_id.to_s)
  end

  def self.repo_path_for(chat_session, repository)
    path_for(chat_session).join("repositories", repository.owner, repository.name)
  end

  def self.agent_home_for(chat_session, provider)
    agent_homes_root_for_id(chat_session.id).join(provider.to_s)
  end

  # Parent directory holding every provider agent home for one chat
  # (Codex session transcripts, auth.json, Claude settings, ...).
  def self.agent_homes_root_for_id(chat_session_id)
    data_root.join("agent_homes", "chats", chat_session_id.to_s)
  end

  def self.ensure_root!(chat_session)
    new(chat_session).ensure_root!
  end

  def self.attach_repository!(chat_session, repository)
    new(chat_session).attach_repository!(repository)
  end

  # Removes the workspace directory AND the per-chat agent homes.
  # Agent homes live outside the workspace dir (Codex transcripts,
  # auth.json), so pruning only the workspace would leak them forever.
  def self.destroy!(chat_session)
    remove_artifacts_for_id!(chat_session.id, recorded_workspace_path: chat_session.workspace_path)
  end

  # Filesystem cleanup for a chat that may no longer have a DB row.
  # Every path is re-derived from the integer chat id via the path
  # helpers above — never taken raw from a client. A recorded
  # workspace_path (captured off the row before destroy) is honored
  # only when it resolves inside SYRUS_DATA_ROOT and is not the data
  # root itself; anything else is ignored rather than rm_rf'd.
  def self.remove_artifacts_for_id!(chat_session_id, recorded_workspace_path: nil)
    id = Integer(chat_session_id)
    raise ArgumentError, "chat_session_id must be positive" unless id.positive?

    paths = [ workspace_root_for_id(id), agent_homes_root_for_id(id) ]
    paths << recorded_workspace_path if recorded_workspace_path.present?

    paths.filter_map { |path| safe_data_root_path(path) }
         .uniq
         .each { |path| FileUtils.rm_rf(path.to_s) }
  end

  # nil unless the candidate is an absolute path strictly inside
  # SYRUS_DATA_ROOT (never the root itself, never `/`).
  def self.safe_data_root_path(path)
    return nil if path.blank?

    candidate = Pathname.new(path.to_s).cleanpath
    return nil unless candidate.absolute?

    root = data_root.cleanpath
    return nil if candidate == root
    return nil unless candidate.to_s.start_with?("#{root}#{File::SEPARATOR}")

    candidate
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

  # Walks chat-workspaces/ and agent_homes/chats/ and removes any
  # directory whose ChatSession no longer exists — heals leaks from
  # the era when chat deletion ran rm_rf on the web pod (where the
  # worker PVC isn't mounted) and never touched agent homes at all.
  def self.sweep_orphans!
    n = 0

    [ data_root.join("chat-workspaces"), data_root.join("agent_homes", "chats") ].each do |root|
      next unless root.exist?

      root.each_child do |child|
        next unless child.directory?

        id = Integer(child.basename.to_s, exception: false)
        next unless id&.positive?
        next if ChatSession.exists?(id: id)

        FileUtils.rm_rf(child.to_s)
        n += 1
      rescue StandardError => e
        Rails.logger.warn("[ChatWorkspace] orphan sweep error on #{child}: #{e.class}: #{e.message}")
      end
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
    default_branch = repository.default_branch
    @git.run(
      "fetch",
      authenticated_url(repository),
      "+refs/heads/#{default_branch}:refs/remotes/origin/#{default_branch}",
      "--prune",
      chdir: path.to_s,
      env: @env
    )
    @git.run("checkout", default_branch, chdir: path.to_s)
    @git.run("merge", "--ff-only", "origin/#{default_branch}", chdir: path.to_s)
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
