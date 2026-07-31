require "fileutils"
require "find"
require "open3"

# Persistent per-ChatSession workspace used by top-level chat inspection.
# Unlike WorkflowWorkspace, this workspace is long-lived and is not reset
# between turns. Repositories are cloned lazily under the session root.
class ChatWorkspace
  CLONE_DEPTH = 50
  EXCLUDE_ENTRY = ".syrus/".freeze
  # Remote tag ref that safely backs up a reclaimed coding checkout's
  # committed and uncommitted work when the checkout is based on the default
  # branch (see reclaim/restore below). Deterministic per chat, so its
  # existence on the remote — not a DB column — is the source of truth.
  CODING_WIP_TAG_PREFIX = "syrus-wip/chat-".freeze
  # A Coding-Mode checkout (writable full clone + installed deps, ~1-2 GB) is
  # reclaimed after this much inactivity; resume re-materializes it
  # transparently from the pushed branch (+ WIP tag).
  RECLAIM_IDLE_CODING_AFTER = 48.hours
  EXCLUDED_DIR_NAMES = %w[.git .syrus node_modules].to_set.freeze
  MAX_FILE_BYTES = 500.kilobytes
  MAX_COMMIT_MESSAGE_BYTES = 300
  COMMIT_SHA_PATTERN = /\A[0-9a-fA-F]{7,40}\z/

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

  # Sets up the writable coding checkout for Coding Mode. Idempotent: if a
  # restore/source ref is already recorded in coding_checkout_branch, this is a
  # no-op while the checkout remains on disk. New standalone chat-authored work
  # stays on the repository default branch; immutable handoff branches are
  # created later by CodingHandoffCapture. Existing Job work can still record a
  # Job branch via ensure_job_branch_checkout!.
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

  def self.coding_checkout_snapshot(chat_session, repository)
    path = repo_path_for(chat_session, repository)
    git_dir = path.join(".git")
    {
      path: path,
      exists: git_dir.directory?,
      configured_branch: chat_session.coding_checkout_branch,
      current_branch: git_value(path, "branch", "--show-current"),
      head_sha: git_value(path, "rev-parse", "--short=12", "HEAD"),
      default_branch: repository.default_branch,
      prepare_status: chat_session.coding_checkout_prepare_status,
      prepare_started_at: chat_session.coding_checkout_prepare_started_at,
      prepare_finished_at: chat_session.coding_checkout_prepare_finished_at,
      prepare_failure: chat_session.coding_checkout_prepare_failure
    }
  end

  def self.git_value(path, *args)
    return nil unless path.join(".git").directory?

    output, status = Open3.capture2e("git", *args, chdir: path.to_s)
    status.success? ? output.strip.presence : nil
  rescue StandardError
    nil
  end

  # Discards the coding checkout. For standalone Coding Mode this is usually a
  # default-branch checkout, so there is no chat branch to delete; for existing
  # Job branches we only delete non-default refs. Clears coding_checkout_branch
  # and coding_checkout_uncommitted on the session.
  def self.cancel_coding_checkout!(chat_session, repository)
    new(chat_session).cancel_coding_checkout!(repository)
  end

  # Sets up a writable coding checkout on an existing Job branch.
  # Idempotent: if coding_checkout_branch is already set to branch_name,
  # returns immediately. On first call, removes any existing checkout and
  # replaces it with a full clone checked out at the existing Job branch.
  def self.ensure_job_branch_checkout!(chat_session, repository, branch_name)
    new(chat_session).ensure_job_branch_checkout!(repository, branch_name)
  end

  # Returns { files: ["path/to/file", ...], checkout_branch: "..." }
  # for the coding checkout. Files are sorted and exclude .git, .syrus,
  # and node_modules trees. Returns nil if the checkout does not exist.
  def self.file_tree(chat_session, repository, ref: nil)
    new(chat_session).file_tree(repository, ref: ref)
  end

  # Returns { content: "...", binary: false, too_large: false } or
  # { content: nil, binary: true } / { content: nil, too_large: true, size: N }.
  # relative_path is validated to stay within the checkout directory.
  # Returns nil if the file or checkout does not exist.
  def self.file_content(chat_session, repository, relative_path, ref: nil)
    new(chat_session).file_content(repository, relative_path, ref: ref)
  end

  # Returns the unified diff for the coding checkout.
  # mode :cumulative => git diff origin/<default>  (all changes vs remote base)
  # mode :turn       => git diff HEAD              (uncommitted changes only)
  # Returns "" on any error or if the checkout does not exist.
  def self.coding_diff(chat_session, repository, mode: :cumulative, ref: nil)
    new(chat_session).coding_diff(repository, mode: mode, ref: ref)
  end

  # Returns up to 50 recent commits on the coding checkout branch.
  def self.coding_commits(chat_session, repository)
    new(chat_session).coding_commits(repository)
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

  # Fully destroys idle chat workspaces (workspace dir + agent homes) and
  # resets the session. Skips Coding-Mode checkouts: those hold committable
  # work and are reclaimed (with a git backup) by reclaim_idle_coding_checkouts!
  # instead of being blindly deleted.
  def self.prune_idle!(older_than:)
    cutoff = older_than.ago
    n = 0

    ChatSession.where.not(workspace_path: nil)
               .where(coding_checkout_branch: nil)
               .where("COALESCE(last_message_at, updated_at) < ?", cutoff)
               .find_each do |chat_session|
      destroy!(chat_session)
      chat_session.update_columns(workspace_path: nil, updated_at: Time.current)
      n += 1
    end

    n
  end

  # Reclaims Coding-Mode checkouts idle longer than `older_than`, backing up
  # any un-pushed / uncommitted work to the remote first. Returns bytes freed.
  def self.reclaim_idle_coding_checkouts!(older_than:)
    cutoff = older_than.ago
    freed = 0

    ChatSession.where.not(coding_checkout_branch: nil)
               .where.not(workspace_path: nil)
               .where("COALESCE(last_message_at, updated_at) < ?", cutoff)
               .find_each do |chat_session|
      freed += reclaim_coding_checkout!(chat_session)
    rescue StandardError => e
      Rails.logger.warn("[ChatWorkspace] idle coding reclaim failed for chat #{chat_session.id}: #{e.class}: #{e.message}")
    end

    freed
  end

  # Enforces the instance-wide byte budget on retained Coding-Mode checkouts by
  # LRU-evicting the least-recently-active ones (each safely backed up first)
  # until total on-disk size is under budget. 0/negative budget = disabled.
  # Returns bytes freed.
  def self.reclaim_coding_over_budget!(budget_bytes:)
    return 0 if budget_bytes.to_i <= 0

    entries = ChatSession.where.not(coding_checkout_branch: nil)
                         .where.not(workspace_path: nil)
                         .find_each.filter_map do |chat_session|
      repository = chat_session.repository
      next unless repository

      path = repo_path_for(chat_session, repository)
      next unless path.join(".git").directory?

      {
        chat_session: chat_session,
        repository: repository,
        bytes: du_bytes(path),
        active_at: chat_session.last_message_at || chat_session.updated_at
      }
    end

    total = entries.sum { |e| e[:bytes] }
    return 0 if total <= budget_bytes

    freed = 0
    entries.sort_by { |e| e[:active_at] }.each do |entry|
      break if (total - freed) <= budget_bytes

      freed += new(entry[:chat_session]).reclaim_coding_checkout!(entry[:repository])
    rescue StandardError => e
      Rails.logger.warn("[ChatWorkspace] budget coding reclaim failed for chat #{entry[:chat_session].id}: #{e.class}: #{e.message}")
    end

    freed
  end

  # Reclaims one chat's Coding-Mode checkout (backup + delete). Returns bytes freed.
  def self.reclaim_coding_checkout!(chat_session, repository = nil)
    repository ||= chat_session.repository
    return 0 unless repository

    new(chat_session).reclaim_coding_checkout!(repository)
  end

  # On-disk size of a path in bytes. Uses `du -sk` (KB) for portability across
  # GNU (Linux worker) and BSD (macOS dev) — `du -sb` is GNU-only.
  def self.du_bytes(path)
    return 0 unless File.exist?(path.to_s)

    out, status = Open3.capture2e("du", "-sk", path.to_s)
    return 0 unless status.success?

    out.to_i * 1024
  rescue StandardError
    0
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

  # Sets up a writable full-clone coding checkout on the repository default
  # branch. The default branch is just the local working ref; accepted
  # submit_coding_changes captures HEAD to an immutable `syrus/chat-...-handoff`
  # branch instead of requiring a persistent `syrus-chat-<id>` branch. The
  # coding_checkout_branch column remains as the restore/source ref for reclaim.
  def ensure_coding_checkout!(repository)
    path = self.class.repo_path_for(@chat_session, repository)
    existing_branch = @chat_session.coding_checkout_branch

    if existing_branch.present?
      # Already initialized. If the checkout is on disk, this is the normal
      # no-op. If it's gone, it was reclaimed to free disk (see
      # reclaim_coding_checkout!) — transparently re-materialize it, restoring
      # any uncommitted work, before the agent runs this turn. The agent must
      # never be able to tell the workspace was deleted.
      return path if path.join(".git").directory?

      ensure_root!
      restore_coding_checkout!(repository, path, existing_branch)
      @chat_session.chat_attachments.find_or_create_by!(attachable: repository)
      write_relay_credentials!
      return path
    end

    ensure_root!
    branch = repository.default_branch

    # Remove any existing shallow checkout so the full clone gets a clean slate.
    FileUtils.rm_rf(path.to_s) if path.join(".git").directory?

    full_clone!(repository, path)
    @chat_session.update_columns(coding_checkout_branch: branch)
    @chat_session.chat_attachments.find_or_create_by!(attachable: repository)
    enqueue_prepare!(repository)
    write_relay_credentials!
    path
  end

  # Frees a Coding-Mode checkout's disk (the ~1-2 GB clone + installed deps)
  # while losing nothing. Default-branch chat work is backed up to the per-chat
  # WIP tag so Syrus never pushes local chat commits to the repository default
  # branch. Existing Job or user-created non-default branches are pushed to
  # their matching remote branch, with dirty work additionally snapshotted in
  # the WIP tag. Only after backup succeeds is the on-disk checkout removed.
  # `coding_checkout_branch` stays set to the source/restore ref so a later turn
  # re-materializes the checkout via ensure_coding_checkout!. Returns bytes freed.
  def reclaim_coding_checkout!(repository)
    branch = @chat_session.coding_checkout_branch
    return 0 if branch.blank?

    path = self.class.repo_path_for(@chat_session, repository)
    return 0 unless path.join(".git").directory?

    bytes = self.class.du_bytes(path)
    branch = backup_coding_checkout!(repository, path, branch)
    @chat_session.update_columns(coding_checkout_branch: branch) if branch != @chat_session.coding_checkout_branch
    FileUtils.rm_rf(path.to_s)
    clear_relay_credentials!
    bytes
  end

  # Sets up a writable coding checkout on an existing Job branch.
  # Idempotent: if coding_checkout_branch already equals branch_name, no-op.
  # Removes any existing checkout, then clones the repo directly at the given
  # branch so the agent can iterate on the Job's existing implementation.
  def ensure_job_branch_checkout!(repository, branch_name)
    return if @chat_session.coding_checkout_branch == branch_name

    ensure_root!
    path = self.class.repo_path_for(@chat_session, repository)

    FileUtils.rm_rf(path.to_s) if path.join(".git").directory?
    full_clone_at_branch!(repository, path, branch_name)
    @chat_session.update_columns(coding_checkout_branch: branch_name)
    @chat_session.chat_attachments.find_or_create_by!(attachable: repository)
    enqueue_prepare!(repository)
    path
  end

  # Resets the coding checkout: switches to the default branch, deletes any
  # non-default recorded branch locally/remotely, and clears the coding checkout
  # state on the session.
  def cancel_coding_checkout!(repository)
    branch = @chat_session.coding_checkout_branch
    return unless branch.present?

    path = self.class.repo_path_for(@chat_session, repository)
    default_branch = repository.default_branch

    if path.join(".git").directory?
      @git.run("checkout", default_branch, chdir: path.to_s, env: @env) rescue nil

      unless branch == default_branch
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

      # Drop any WIP backup tag left by a prior reclaim (best-effort).
      begin
        @git.run(
          "push", authenticated_url(repository), "--delete", "refs/tags/#{wip_tag}",
          chdir: path.to_s, env: @env
        )
      rescue StandardError
        # Tag may not exist; silently continue
      end
    end

    @chat_session.update_columns(
      coding_checkout_branch: nil,
      coding_checkout_uncommitted: false
    )
    clear_relay_credentials!
  end

  def file_tree(repository, ref: nil)
    path = self.class.repo_path_for(@chat_session, repository)
    return nil unless path.join(".git").directory?

    return file_tree_at_ref(path, ref) if ref.present?

    files = []
    Find.find(path.to_s) do |entry|
      basename = File.basename(entry)
      if File.directory?(entry)
        Find.prune if self.class::EXCLUDED_DIR_NAMES.include?(basename)
        next
      end
      relative = Pathname.new(entry).relative_path_from(path).to_s
      files << relative
    end

    {
      files: files.sort,
      checkout_branch: @chat_session.coding_checkout_branch
    }
  end

  def file_content(repository, relative_path, ref: nil)
    path = self.class.repo_path_for(@chat_session, repository)
    return nil unless path.join(".git").directory?

    safe = safe_checkout_path(path, relative_path)
    return nil unless safe
    normalized_relative_path = safe.relative_path_from(path).to_s
    return file_content_at_ref(path, normalized_relative_path, ref) if ref.present?
    return nil unless safe&.file?

    size = safe.size
    if size > self.class::MAX_FILE_BYTES
      return { content: nil, binary: false, too_large: true, size: size }
    end

    raw = safe.binread
    if raw.include?("\x00")
      return { content: nil, binary: true, too_large: false }
    end

    {
      content: raw.encode(Encoding::UTF_8, invalid: :replace, undef: :replace),
      binary: false,
      too_large: false
    }
  end

  def coding_diff(repository, mode: :cumulative, ref: nil)
    path = self.class.repo_path_for(@chat_session, repository)
    return "" unless path.join(".git").directory?

    if ref.present?
      return "" unless valid_commit_ref?(ref)

      out, status = Open3.capture2e({ "GIT_TERMINAL_PROMPT" => "0" }, "git", "diff", "#{ref}^..#{ref}", chdir: path.to_s)
      return status.success? ? out : ""
    end

    default_branch = repository.default_branch

    if mode.to_sym == :turn
      # Uncommitted changes vs last commit
      out, status = Open3.capture2e({ "GIT_TERMINAL_PROMPT" => "0" }, "git", "diff", "HEAD", chdir: path.to_s)
      status.success? ? out : ""
    else
      # All changes from remote base to current working tree
      out, status = Open3.capture2e({ "GIT_TERMINAL_PROMPT" => "0" }, "git", "diff", "origin/#{default_branch}", chdir: path.to_s)
      status.success? ? out : ""
    end
  rescue StandardError
    ""
  end

  def coding_commits(repository)
    path = self.class.repo_path_for(@chat_session, repository)
    return nil unless path.join(".git").directory?

    out, status = Open3.capture2e(
      { "GIT_TERMINAL_PROMPT" => "0" },
      "git", "log", "--format=%H %ai %s", "-n", "50",
      chdir: path.to_s
    )
    return { commits: [] } unless status.success?

    commits = out.lines.filter_map do |raw_line|
      line = raw_line.chomp
      next unless line =~ /\A([0-9a-f]{40}) (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}) (.*)\z/

      {
        sha: Regexp.last_match(1),
        date: Regexp.last_match(2),
        message: Regexp.last_match(3).to_s.safe_byteslice(0, self.class::MAX_COMMIT_MESSAGE_BYTES)
      }
    end

    { commits: commits }
  rescue StandardError
    { commits: [] }
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
    full_clone_at_branch!(repository, path, repository.default_branch)
  end

  def full_clone_at_branch!(repository, path, branch)
    FileUtils.mkdir_p(path.dirname.to_s)
    @git.run(
      "clone",
      "--branch", branch,
      "--no-tags", authenticated_url(repository), path.to_s,
      env: @env
    )
    @git.run("remote", "set-url", "origin", repository.remote_url, chdir: path.to_s)
    GitInfoExclude.ensure_entry!(path, EXCLUDE_ENTRY)
  end

  def wip_tag
    "#{self.class::CODING_WIP_TAG_PREFIX}#{@chat_session.id}"
  end

  # Pushes everything needed to reproduce the checkout to the remote.
  # Returns the source ref to store in coding_checkout_branch for restoration.
  # Raises if a push fails, so the caller keeps the on-disk checkout.
  def backup_coding_checkout!(repository, path, branch)
    url = authenticated_url(repository)
    current = self.class.git_value(path, "branch", "--show-current").presence || branch

    if current == repository.default_branch
      backup_default_branch_checkout!(url, path, repository.default_branch)
      return current
    end

    # Preserve any unpushed real commits on the active non-default branch.
    @git.run("push", url, "#{current}:refs/heads/#{current}", chdir: path.to_s, env: @env)

    # Snapshot uncommitted work (git status --porcelain includes untracked;
    #    .gitignored files like node_modules are excluded, so deps aren't backed
    #    up — they're re-installed on restore).
    return current unless self.class.uncommitted_changes?(path)

    @git.run("add", "-A", chdir: path.to_s, env: @env)
    @git.run(
      "-c", "user.email=syrus@localhost", "-c", "user.name=Syrus",
      "commit", "-m", "syrus wip backup", "--no-verify",
      chdir: path.to_s, env: @env
    )
    wip_sha, = Open3.capture2e(@env, "git", "rev-parse", "HEAD", chdir: path.to_s)
    @git.run("push", url, "#{wip_sha.strip}:refs/tags/#{wip_tag}", chdir: path.to_s, env: @env)
    current
  end

  # For default-branch chat work, never push `HEAD:refs/heads/<default>`.
  # Committed chat changes and an optional final WIP commit are instead stored
  # under the per-chat backup tag and restored into the local checkout later.
  def backup_default_branch_checkout!(url, path, default_branch)
    clean = !self.class.uncommitted_changes?(path)
    return if clean && rev_parse_path(path, "HEAD") == rev_parse_path(path, "refs/remotes/origin/#{default_branch}")

    backup_sha = if !clean
      @git.run("add", "-A", chdir: path.to_s, env: @env)
      @git.run(
        "-c", "user.email=syrus@localhost", "-c", "user.name=Syrus",
        "commit", "-m", "syrus wip backup", "--no-verify",
        chdir: path.to_s, env: @env
      )
      rev_parse_path(path, "HEAD")
    else
      rev_parse_path(path, "HEAD")
    end

    @git.run("push", url, "#{backup_sha}:refs/tags/#{wip_tag}", chdir: path.to_s, env: @env)
  end

  # Re-materializes a reclaimed coding checkout from the remote, transparently
  # restoring any uncommitted work backed up as a WIP tag. Afterwards the
  # working tree looks exactly as it did before reclaim.
  def restore_coding_checkout!(repository, path, branch)
    FileUtils.rm_rf(path.to_s) if path.exist?
    full_clone_at_branch!(repository, path, branch)

    if remote_wip_tag_exists?(repository)
      restore_wip_tag!(repository, path, default_branch: branch == repository.default_branch)
    end

    GitInfoExclude.ensure_entry!(path, EXCLUDE_ENTRY)
    enqueue_prepare!(repository)
  end

  def restore_wip_tag!(repository, path, default_branch:)
    url = authenticated_url(repository)
    @git.run("fetch", url, "+refs/tags/#{wip_tag}:refs/tags/#{wip_tag}", chdir: path.to_s, env: @env)

    if default_branch
      restore_default_branch_wip_tag!(path)
    else
      # The WIP commit's parent is the branch tip we just cloned, so applying it
      # is a clean patch. `-n` leaves it staged; `reset` unstages so it reads as
      # ordinary uncommitted work (new files become untracked again).
      @git.run("cherry-pick", "-n", wip_tag, chdir: path.to_s, env: @env)
      @git.run("reset", chdir: path.to_s, env: @env)
      # `cherry-pick -n` leaves CHERRY_PICK_HEAD set; clear the sequencer state
      # so the agent's next `git commit` behaves normally (no reused WIP message).
      @git.run("cherry-pick", "--quit", chdir: path.to_s, env: @env) rescue nil
    end

    begin
      @git.run("push", url, "--delete", "refs/tags/#{wip_tag}", chdir: path.to_s, env: @env)
    rescue StandardError
    end
    @git.run("tag", "-d", wip_tag, chdir: path.to_s, env: @env) rescue nil
  end

  def restore_default_branch_wip_tag!(path)
    @git.run("reset", "--hard", wip_tag, chdir: path.to_s, env: @env)
    return unless git_subject(path, "HEAD") == "syrus wip backup"

    @git.run("reset", "HEAD~1", chdir: path.to_s, env: @env)
  end

  def rev_parse_path(path, ref)
    @git.run("rev-parse", ref, chdir: path.to_s, env: @env).strip
  end

  def git_subject(path, ref)
    @git.run("log", "-1", "--format=%s", ref, chdir: path.to_s, env: @env).strip
  rescue StandardError
    nil
  end

  def enqueue_prepare!(repository)
    now = Time.current
    @chat_session.update_columns(
      coding_checkout_prepare_status: "queued",
      coding_checkout_prepare_started_at: nil,
      coding_checkout_prepare_finished_at: nil,
      coding_checkout_prepare_failure: nil,
      updated_at: now
    )
    ChatWorkspacePrepareJob.perform_later(@chat_session.id, repository.id)
  end

  def remote_wip_tag_exists?(repository)
    out, status = Open3.capture2e(
      @env, "git", "ls-remote", "--tags", authenticated_url(repository), "refs/tags/#{wip_tag}"
    )
    status.success? && out.strip.present?
  rescue StandardError
    false
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

  def write_relay_credentials!
    relay_address = ChatWorkspaceRelay.relay_address
    return unless relay_address.present? && @chat_session.coding_relay_address.blank?

    token = SecureRandom.hex(32)
    @chat_session.update_columns(coding_relay_address: relay_address, coding_relay_token: token)
  end

  def clear_relay_credentials!
    @chat_session.update_columns(coding_relay_address: nil, coding_relay_token: nil)
  end

  # Returns a Pathname for relative_path resolved within checkout_dir, or nil
  # if the path is blank, contains traversal sequences, or escapes the root.
  def safe_checkout_path(checkout_dir, relative_path)
    return nil if relative_path.blank?

    candidate = checkout_dir.join(relative_path).cleanpath
    root = checkout_dir.cleanpath
    return nil if candidate == root
    return nil unless candidate.to_s.start_with?("#{root}#{File::SEPARATOR}")

    candidate
  end

  def file_content_at_ref(checkout_dir, relative_path, ref)
    return nil unless valid_commit_ref?(ref)

    spec = "#{ref}:#{relative_path}"
    type_out, type_status = Open3.capture2e(
      { "GIT_TERMINAL_PROMPT" => "0" },
      "git", "cat-file", "-t", spec,
      chdir: checkout_dir.to_s
    )
    return nil unless type_status.success? && type_out.strip == "blob"

    size_out, size_status = Open3.capture2e(
      { "GIT_TERMINAL_PROMPT" => "0" },
      "git", "cat-file", "-s", spec,
      chdir: checkout_dir.to_s
    )
    return nil unless size_status.success?

    size = size_out.to_i
    if size > self.class::MAX_FILE_BYTES
      return { content: nil, binary: false, too_large: true, size: size }
    end

    raw, show_status = Open3.capture2e(
      { "GIT_TERMINAL_PROMPT" => "0" },
      "git", "show", spec,
      chdir: checkout_dir.to_s
    )
    return nil unless show_status.success?

    if raw.include?("\x00")
      return { content: nil, binary: true, too_large: false }
    end

    {
      content: raw.encode(Encoding::UTF_8, invalid: :replace, undef: :replace),
      binary: false,
      too_large: false
    }
  end

  def file_tree_at_ref(checkout_dir, ref)
    return nil unless valid_commit_ref?(ref)

    out, status = Open3.capture2e(
      { "GIT_TERMINAL_PROMPT" => "0" },
      "git", "ls-tree", "-r", "-z", "--name-only", ref,
      chdir: checkout_dir.to_s
    )
    return nil unless status.success?

    files = out.split("\0").reject do |relative_path|
      relative_path.blank? || relative_path.split("/").any? { |part| self.class::EXCLUDED_DIR_NAMES.include?(part) }
    end

    {
      files: files.sort,
      checkout_branch: @chat_session.coding_checkout_branch
    }
  end

  def valid_commit_ref?(ref)
    ref.to_s.match?(self.class::COMMIT_SHA_PATTERN)
  end
end
