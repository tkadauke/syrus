require "fileutils"
require "tmpdir"

class Coworkers::ChatWorkspaceLifecycle
  include Syrus::Plugin::ChatWorkspaceLifecycle
  MAX_PUSH_ATTEMPTS = 3
  MAX_RESOLUTION_ATTEMPTS = 2
  RESOLUTION_TIMEOUT = 1.hour
  BACKGROUND_GIT_TIMEOUT = 1.minute

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

  def finalize!(schedule_background: true)
    path = checkout_path
    return unless path.join(".git").directory?
    pending = active_conflict
    return resolve_pending_conflict!(path, pending) if pending

    conflicts = unmerged_files(path)
    if conflicts.any?
      terminal = terminal_conflict(files: conflicts, source_branch: chat_branch)
      if terminal && conflict_markers(path, conflicts).empty?
        terminal.update!(state: "pending")
        return resolve_pending_conflict!(path, terminal)
      end
      conflict = terminal ||
        record_conflict!(files: conflicts, versions: conflict_versions(path, conflicts),
          detail: "The conflict still needs manual resolution.", source_branch: chat_branch)
      conflict.update!(state: "failed")
      return post_conflict!(files: conflicts, detail: conflict.detail, conflict:)
    end

    commit_turn!(path)
    Coworkers::UnsavedWorkspace.new(@chat).attempt(branch: chat_branch, path:, operation: "chat_branch", schedule_background:) do
      push_chat_branch!(path)
      outcome = merge_into_home!(chat_branch)
      resolve_failed_conflicts!(chat_branch) if outcome == :merged
      outcome
    end
  end

  # Background runs share the exact home-branch merge/retry/conflict path used
  # at chat turn end. Their immutable run ref preserves the completed work when
  # a concurrent chat changed the home branch incompatibly.
  def finalize_background!(path:, workflow:)
    path = Pathname(path)
    return :unavailable unless path.join(".git").directory?

    with_git_timeout(BACKGROUND_GIT_TIMEOUT) do
      source_branch = "coworkers/run/#{@coworker.id}-#{workflow.id}"
      @git.configure_author(identity, chdir: path.to_s)
      if git_run("status", "--porcelain", chdir: path.to_s).present?
        git_run("add", "--all", chdir: path.to_s)
        git_run("commit", "-m", "Update @#{@coworker.handle} from background run", chdir: path.to_s)
      end
      push_guard.allow!(source_branch)
      git_run("push", @remote_url, "HEAD:refs/heads/#{source_branch}", chdir: path.to_s, env: @env)
      merge_into_home!(source_branch, conflict_checkout: path)
    end
  end

  def expire_conflict!(conflict)
    conflict.with_lock do
      return :resolved unless conflict.state == "pending"
      return :pending_resolution if conflict.expires_at.future?

      conflict.update!(state: "failed", detail: "Automatic workspace conflict resolution timed out.")
      post_conflict!(files: Array(conflict.files), detail: conflict.detail,
        source_branch: conflict.source_branch, ref: conflict.recovery_ref, conflict:)
    end
  end

  private

  def home_branch = "coworkers/#{@coworker.handle}"
  def chat_branch = "coworkers/chat/#{@coworker.id}-#{@chat.id}"
  def identity = Coworkers::GitIdentity.new(name: @coworker.name, handle: @coworker.handle)
  def push_guard = (@push_guard ||= Coworkers::PushGuard.new(coworker: @coworker))
  def checkout_path = ChatWorkspace.repo_path_for(@chat, @repository)

  def workspace_repository
    @coworker.workspace_repository
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
      expected_home_sha = git_run("rev-parse", "HEAD", chdir: dir).strip
      git_run("fetch", @remote_url, "refs/heads/#{source_branch}:refs/remotes/origin/coworker-source", chdir: dir, env: @env)
      merge = git_capture("merge", "--no-edit", "origin/coworker-source", chdir: dir, env: @env)
      unless merge.success?
        resolved = resolve_compatible_markdown_conflicts!(dir)
        return report_conflict!(dir, merge, source_branch:, conflict_checkout:) unless resolved
        git_run("commit", "--no-edit", chdir: dir, env: { "GIT_EDITOR" => "true" })
      end

      Coworkers::WorkspaceCandidateValidator.new(dir, git: @git).validate!(base_sha: expected_home_sha)
      candidate_sha = git_run("rev-parse", "HEAD", chdir: dir).strip
      destination = push_guard.allow!(home_branch)
      git_run("push", @remote_url,
        "--force-with-lease=refs/heads/#{destination}:#{expected_home_sha}",
        "HEAD:refs/heads/#{destination}", chdir: dir, env: @env)
      verify_remote_ref!(destination, candidate_sha)
      :merged
    rescue GitRunner::GitError => error
      raise unless error.output.match?(/non-fast-forward|fetch first|failed to push some refs/i)
      :retry
    rescue Coworkers::WorkspaceCandidateValidator::ValidationError => error
      recovery_ref = snapshot_invalid_candidate!(dir)
      report_invalid_candidate!(source_branch, conflict_checkout, error, recovery_ref:)
    end
  end

  def resolve_compatible_markdown_conflicts!(path)
    files = unmerged_files(path)
    return false if files.empty? || files.any? { |relative| File.extname(relative).downcase != ".md" }

    files.each do |relative|
      base = index_blob(path, 1, relative)
      ours = index_blob(path, 2, relative)
      theirs = index_blob(path, 3, relative)
      merged = additive_merge(base, ours, theirs)
      return false unless merged

      candidate = Syrus::PathJail.resolve!(path, relative)
      File.binwrite(candidate, merged)
      git_run("add", "--", relative, chdir: path.to_s)
    end
    unmerged_files(path).empty?
  end

  def index_blob(path, stage, relative)
    git_run("show", ":#{stage}:#{relative}", chdir: path.to_s)
  rescue GitRunner::GitError
    nil
  end

  def additive_merge(base, ours, theirs)
    return unless base && ours && theirs
    base_lines = base.lines
    ours_groups = additive_groups(base_lines, ours.lines)
    theirs_groups = additive_groups(base_lines, theirs.lines)
    return unless ours_groups && theirs_groups

    (0..base_lines.length).flat_map do |index|
      # Identical additions express the same table row or prose insertion, so
      # retaining it once preserves both intents without manufacturing a duplicate.
      additions = (ours_groups[index] + theirs_groups[index]).uniq
      index < base_lines.length ? additions + [ base_lines[index] ] : additions
    end.join
  end

  def additive_groups(base_lines, candidate_lines)
    groups = Array.new(base_lines.length + 1) { [] }
    cursor = 0
    candidate_lines.each do |line|
      if cursor < base_lines.length && line == base_lines[cursor]
        cursor += 1
      else
        groups[cursor] << line
      end
    end
    cursor == base_lines.length ? groups : nil
  end

  def verify_remote_ref!(branch, candidate_sha)
    line = git_run("ls-remote", "--heads", @remote_url, "refs/heads/#{branch}", env: @env).lines.first
    actual_sha = line.to_s.split.first
    return if actual_sha == candidate_sha

    raise GitRunner::GitError.new([ "ls-remote", branch ], 1,
      "pushed home ref verification failed: expected #{candidate_sha}, observed #{actual_sha.presence || 'missing'}")
  end

  def report_invalid_candidate!(source_branch, source_path, error, recovery_ref:)
    relative = error.relative_path.presence || "workspace"
    detail = error.message
    content = safe_conflict_content(source_path, relative) || "[Candidate validation failed: #{detail}]"
    record_conflict!(files: [ relative ], versions: { relative => content }, detail:, source_branch:, ref: recovery_ref)
    :pending_resolution
  end

  def report_conflict!(merge_path, merge, source_branch:, conflict_checkout:)
    files = unmerged_files(merge_path)
    leave_conflict_in_checkout!(conflict_checkout)
    conflict_ref = snapshot_background_conflict!(conflict_checkout, source_branch) if background_run_branch?(source_branch)
    record_conflict!(files:, versions: conflict_versions(conflict_checkout, files),
      detail: merge.stderr.to_s.last(500), source_branch:, ref: conflict_ref)
    :pending_resolution
  end

  def record_conflict!(files:, versions:, detail:, source_branch:, ref: nil)
    conflict = active_conflict || Coworkers::WorkspaceConflict.new(chat_session: @chat, repository: @repository)
    fresh = conflict.new_record?
    conflict.update!(source_branch:, recovery_ref: ref || conflict.recovery_ref, files:, versions:, detail:,
      attempt_count: conflict.persisted? ? conflict.attempt_count : 0, state: "pending",
      notified_at: fresh ? nil : conflict.notified_at, resolved_at: nil,
      expires_at: fresh ? RESOLUTION_TIMEOUT.from_now : conflict.expires_at)
    Coworkers::WorkspaceConflictTimeoutJob.set(wait_until: conflict.expires_at).perform_later(conflict.id) if fresh
    conflict
  end

  def resolve_pending_conflict!(path, conflict)
    files = Array(conflict.files)
    return :pending_resolution unless resolution_changed?(path, conflict)

    conflict.increment!(:attempt_count)
    markers = conflict_markers(path, files)
    return retry_or_fail!(conflict, files:, detail: "Conflict markers remain in #{markers.join(', ')}.") if markers.any?

    git_run("add", "--all", chdir: path.to_s)
    remaining = unmerged_files(path)
    return retry_or_fail!(conflict, files:, detail: "Unmerged index entries remain in #{remaining.join(', ')}.") if remaining.any?
    validation = git_capture("diff", "--check", "HEAD", chdir: path.to_s)
    return retry_or_fail!(conflict, files:,
      detail: "#{validation.stdout}#{validation.stderr}".last(500)) unless validation.success?

    commit_turn!(path)
    push_chat_branch!(path)
    outcome = merge_into_home!(chat_branch)
    conflict.update!(state: "resolved", resolved_at: Time.current) if outcome == :merged
    outcome
  rescue GitRunner::GitError => error
    retry_or_fail!(conflict, files:, detail: error.output.to_s.last(500))
  end

  def retry_or_fail!(conflict, files:, detail:)
    if conflict.attempt_count < MAX_RESOLUTION_ATTEMPTS
      conflict.update!(detail:)
      return :pending_resolution
    end

    conflict.update!(state: "failed", detail:)
    post_conflict!(files:, detail:, source_branch: conflict.source_branch, ref: conflict.recovery_ref, conflict:)
  end

  def post_conflict!(files:, detail:, source_branch: chat_branch, ref: nil, conflict: nil)
    return :conflict if conflict&.notified_at?
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
    conflict&.update!(notified_at: Time.current)
    :conflict
  end

  def active_conflict
    Coworkers::WorkspaceConflict.active.find_by(chat_session: @chat, repository: @repository)
  end

  def terminal_conflict(files:, source_branch:)
    Coworkers::WorkspaceConflict.where(chat_session: @chat, repository: @repository, state: "failed", source_branch:)
      .order(id: :desc).detect { |conflict| Array(conflict.files).sort == Array(files).sort }
  end

  def resolve_failed_conflicts!(source_branch)
    Coworkers::WorkspaceConflict.where(chat_session: @chat, repository: @repository,
      state: "failed", source_branch:).update_all(state: "resolved", resolved_at: Time.current, updated_at: Time.current)
  end

  def resolution_changed?(path, conflict)
    conflict.versions.to_h.any? do |relative, original|
      current = safe_conflict_content(path, relative)
      current && current != original
    end
  end

  def conflict_markers(path, files)
    files.select do |relative|
      content = safe_conflict_content(path, relative)
      content.nil? || (!content.include?("\0") && content.match?(/^(?:<<<<<<<|=======|>>>>>>>)(?: |$)/))
    rescue ArgumentError, Encoding::CompatibilityError
      true
    end
  end

  def conflict_versions(path, files)
    files.to_h do |relative|
      [ relative, safe_conflict_content(path, relative) || "[Conflict source unavailable: unsafe or missing file]" ]
    end
  end

  def safe_conflict_content(root, relative)
    candidate = Syrus::PathJail.resolve!(root, relative)
    return if candidate.symlink? || !candidate.file?

    file = Syrus::PathJail.resolve!(root, relative, resolve_symlinks: true)
    File.binread(file, Coworkers::PromptSection::MAX_FILE_BYTES).force_encoding(Encoding::UTF_8).scrub
  rescue Syrus::PathJail::PathEscape, Errno::ENOENT, Errno::EACCES, Errno::ELOOP
    nil
  end

  def unmerged_files(path)
    git_run("diff", "--name-only", "-z", "--diff-filter=U", chdir: path.to_s).split("\0")
  end

  def markdown_link_label(value)
    value.gsub(/[\\\[\]]/) { |character| "\\#{character}" }
  end

  def leave_conflict_in_checkout!(path)
    git_run("fetch", @remote_url, "refs/heads/#{home_branch}:refs/remotes/origin/coworker-home", chdir: path.to_s, env: @env)
    git_capture("merge", "--no-edit", "origin/coworker-home", chdir: path.to_s, env: @env)
  end

  def background_run_branch?(branch)
    branch.start_with?("coworkers/run/")
  end

  def snapshot_background_conflict!(path, source_branch)
    git_run("add", "--all", chdir: path.to_s)
    git_run("commit", "-m", "Preserve @#{@coworker.handle} background run conflict", chdir: path.to_s)
    git_run("push", @remote_url, "HEAD:refs/heads/#{push_guard.allow!(source_branch)}", chdir: path.to_s, env: @env)
    git_run("rev-parse", "HEAD", chdir: path.to_s).strip
  end

  def snapshot_invalid_candidate!(path)
    candidate_sha = git_run("rev-parse", "HEAD", chdir: path.to_s).strip
    branch = push_guard.allow!("coworkers/recovery/#{@coworker.id}-#{candidate_sha}")
    git_run("push", @remote_url, "HEAD:refs/heads/#{branch}", chdir: path.to_s, env: @env)
    candidate_sha
  end

  def clone_branch!(branch, destination)
    git_run("clone", "--branch", branch, "--no-tags", @remote_url, destination, env: @env)
    # Never leave the authenticated transport URL in a checkout exposed to the
    # coworker's shell. Lifecycle operations pass it explicitly when needed.
    git_run("remote", "set-url", "origin", @repository.remote_url, chdir: destination)
  end

  def git_run(*args, **options)
    options[:timeout] = @git_timeout if @git_timeout
    @git.run(*args, **options)
  end

  def git_capture(*args, **options)
    options[:timeout] = @git_timeout if @git_timeout
    @git.capture(*args, **options)
  end

  def with_git_timeout(timeout)
    previous_timeout = @git_timeout
    @git_timeout = timeout
    yield
  ensure
    @git_timeout = previous_timeout
  end
end
