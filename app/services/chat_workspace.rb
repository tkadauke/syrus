require "fileutils"
require "open3"

# Persistent per-ChatSession workspace used by top-level chat inspection.
# Unlike WorkflowWorkspace, this workspace is long-lived and is not reset
# between turns. Repositories are cloned lazily under the session root.
class ChatWorkspace
  CLONE_DEPTH = 50
  EXCLUDE_ENTRY = ".syrus/".freeze
  CODING_CHECKOUT_BRANCH_PREFIX = "syrus-chat-".freeze

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

  # Sets up the writable coding checkout for Coding Mode. Idempotent: if the
  # checkout is already initialized (coding_checkout_branch is set on the
  # session), this is a no-op. On first call, replaces any existing shallow
  # read-only clone with a full clone on a dedicated coding branch.
  def self.ensure_coding_checkout!(chat_session, repository)
    new(chat_session).ensure_coding_checkout!(repository)
  end

  # Returns true if the coding checkout path has uncommitted changes.
  # Uses git status --porcelain; returns false on any error (e.g. checkout
  # not yet initialized).
  def self.uncommitted_changes?(path)
    return false unless Pathname.new(path.to_s).join(".git").directory?

    output, status = Open3.capture2e("git", "status", "--porcelain", chdir: path.to_s)
    status.success? && output.strip.present?
  rescue StandardError
    false
  end

  # Discards the coding checkout: switches back to the default branch,
  # deletes the coding branch locally, and tries to delete the remote branch
  # if it was pushed. Clears coding_checkout_branch and
  # coding_checkout_uncommitted on the session.
  def self.cancel_coding_checkout!(chat_session, repository)
    new(chat_session).cancel_coding_checkout!(repository)
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

  # Sets up a writable full-clone coding checkout on a dedicated branch.
  # Idempotent: if coding_checkout_branch is already set, returns immediately.
  # On first call, removes any existing shallow read-only clone and replaces
  # it with a full (unshallow) clone on a new coding branch.
  def ensure_coding_checkout!(repository)
    return if @chat_session.coding_checkout_branch.present?

    ensure_root!
    path = self.class.repo_path_for(@chat_session, repository)
    branch = "#{self.class::CODING_CHECKOUT_BRANCH_PREFIX}#{@chat_session.id}"

    # Remove any existing shallow checkout so the full clone gets a clean slate.
    FileUtils.rm_rf(path.to_s) if path.join(".git").directory?

    full_clone!(repository, path)
    create_coding_branch!(path, branch)
    @chat_session.update_columns(coding_checkout_branch: branch)
    @chat_session.chat_attachments.find_or_create_by!(attachable: repository)
    path
  end

  # Resets the coding checkout: switches to the default branch, deletes the
  # coding branch locally, tries to delete the remote branch, and clears the
  # coding checkout state on the session.
  def cancel_coding_checkout!(repository)
    branch = @chat_session.coding_checkout_branch
    return unless branch.present?

    path = self.class.repo_path_for(@chat_session, repository)
    default_branch = repository.default_branch

    if path.join(".git").directory?
      # Switch to default branch before deleting the coding branch
      @git.run("checkout", default_branch, chdir: path.to_s, env: @env) rescue nil
      # Delete the local coding branch
      @git.run("branch", "-D", branch, chdir: path.to_s, env: @env) rescue nil
      # Try to delete the remote branch (best-effort; may not have been pushed)
      begin
        @git.run(
          "push", authenticated_url(repository), "--delete", branch,
          chdir: path.to_s, env: @env
        )
      rescue StandardError
        # Remote branch may not exist; silently continue
      end
    end

    @chat_session.update_columns(
      coding_checkout_branch: nil,
      coding_checkout_uncommitted: false
    )
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

  def full_clone!(repository, path)
    FileUtils.mkdir_p(path.dirname.to_s)
    @git.run(
      "clone",
      "--branch", repository.default_branch,
      "--no-tags", authenticated_url(repository), path.to_s,
      env: @env
    )
    @git.run("remote", "set-url", "origin", repository.remote_url, chdir: path.to_s)
    GitInfoExclude.ensure_entry!(path, EXCLUDE_ENTRY)
  end

  def create_coding_branch!(path, branch)
    @git.run("checkout", "-b", branch, chdir: path.to_s, env: @env)
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
