class Coworkers::WorkspaceBrowser
  MAX_FILE_BYTES = 256.kilobytes

  def initialize(coworker:, repository:, user:)
    @coworker = coworker
    @repository = repository
    @reader = RepositoryContent.for(repository, user: user)
  end

  def call(path: nil)
    home = @reader.resolve(home_branch)
    entries, partial = workspace_entries(home)
    selected = selected_file(home, entries, path)
    {
      remote: @repository.remote_url,
      branch: home_branch,
      files: entries.map { |entry| { path: entry.path, type: entry.type } },
      partial: partial,
      selected_file: selected,
      commits: commits(home),
      conflicts: active_conflicts(home)
    }
  end

  private

  def home_branch = "coworkers/#{@coworker.handle}"

  def workspace_entries(revision)
    [ @reader.tree(revision).sort_by(&:path), false ]
  rescue RepositoryContent::Truncated => error
    [ Array(error.partial).sort_by(&:path), true ]
  end

  def selected_file(revision, entries, requested_path)
    path = requested_path.presence
    return unless path && entries.any? { |entry| entry.file? && entry.path == path }

    blob = @reader.read(revision, path, max_bytes: MAX_FILE_BYTES)
    binary = blob.bytes.include?("\0")
    { path: path, content: binary ? "" : blob.text, truncated: blob.truncated, binary: binary }
  rescue RepositoryContent::NotFound
    nil
  end

  def commits(home)
    base = @reader.resolve(@repository.default_branch)
    @reader.history(base: base, head: home).commits.map do |commit|
      chat_id = commit.message[/\bchat (\d+)\b/i, 1]
      {
        sha: commit.sha, message: commit.message, authored_at: commit.authored_at,
        source: chat_id ? "chat" : "run", source_id: chat_id&.to_i
      }
    end
  rescue RepositoryContent::Error
    []
  end

  def active_conflicts(home)
    conflict_records.filter_map do |record|
      branch = record["branch"].to_s
      next unless branch.start_with?("coworkers/chat/") && conflict_active?(home, branch)

      { branch: branch, files: Array(record["files"]), detail: record["detail"] }
    end.uniq { |record| record[:branch] }
  end

  def conflict_records
    chat_ids = @coworker.coworker_chats.select(:chat_session_id)
    @coworker.chat_agents.select(:chat_session_id).then { |rostered| chat_ids = ChatSession.where(id: chat_ids).or(ChatSession.where(id: rostered)).select(:id) }
    ChatMessage.where(chat_session_id: chat_ids, role: "system").order(created_at: :desc).filter_map do |message|
      message.content["coworker_workspace_conflict"] if message.content.is_a?(Hash)
    end
  end

  def conflict_active?(home, branch)
    chat = @reader.resolve(branch)
    !%i[identical behind].include?(@reader.relation(base: home, head: chat))
  rescue RepositoryContent::UnknownRevision
    false
  rescue RepositoryContent::Error
    true
  end
end
