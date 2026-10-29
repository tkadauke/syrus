class Coworkers::WorkspaceBrowser
  MAX_FILE_BYTES = 512.kilobytes
  HISTORY_LIMIT = 50

  def initialize(coworker:, repository:, user:)
    @coworker = coworker
    @repository = repository
    @content = RepositoryContent.for(repository, user: user)
  end

  def call(path: nil)
    revision = @content.resolve(branch)
    entries = @content.tree(revision).sort_by(&:path)
    selected = read_file(revision, entries, path)
    {
      remote: @coworker.workspace_repo,
      branch: branch,
      files: entries.map { |entry| { path: entry.path, type: entry.type, size: entry.size } },
      selected_file: selected,
      commits: @content.commit_log(revision, limit: HISTORY_LIMIT).map { |commit| commit_json(commit) },
      conflicts: conflicts
    }
  rescue RepositoryContent::Truncated => error
    entries = Array(error.partial).sort_by(&:path)
    {
      remote: @coworker.workspace_repo, branch: branch,
      files: entries.map { |entry| { path: entry.path, type: entry.type, size: entry.size } },
      selected_file: nil, commits: [], conflicts: conflicts, partial: true
    }
  end

  private

  def branch = "coworkers/#{@coworker.handle}"

  def read_file(revision, entries, requested_path)
    path = requested_path.to_s.presence || entries.find(&:file?)&.path
    return unless path && entries.any? { |entry| entry.file? && entry.path == path }

    blob = @content.read(revision, path, max_bytes: MAX_FILE_BYTES)
    return { path: path, binary: true, size: blob.size } unless blob.bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?

    { path: path, content: blob.text, size: blob.size, truncated: blob.truncated, markdown: path.downcase.end_with?(".md", ".markdown") }
  end

  def commit_json(commit)
    message = commit.message.to_s
    source = if (match = message.match(/\bchat (\d+)\b/i))
      { type: "chat", id: match[1].to_i, path: "/chats/#{match[1]}" }
    elsif (match = message.match(/\brun (\d+)\b/i))
      { type: "run", id: match[1].to_i, path: "/admin/runs/#{match[1]}/transcript" }
    end
    { sha: commit.sha, short_sha: commit.sha.first(7), message: message, authored_at: commit.authored_at, source: source }
  end

  def conflicts
    @coworker.coworker_chats.includes(chat_session: :messages).filter_map do |link|
      message = link.chat_session.messages.reverse.find { |item| item.content.is_a?(Hash) && item.content["coworker_workspace_conflict"].present? }
      next unless message

      conflict = message.content.fetch("coworker_workspace_conflict")
      next unless conflict_active?(conflict["branch"])

      { chat_id: link.chat_session_id, branch: conflict["branch"], files: conflict["files"], chat_path: "/chats/#{link.chat_session_id}" }
    end
  end

  def conflict_active?(chat_branch)
    home = @content.resolve(branch)
    chat = @content.resolve(chat_branch)
    %i[ahead diverged].include?(@content.relation(base: home, head: chat))
  rescue RepositoryContent::Error
    # The conflict message remains the best cached evidence when a provider
    # cannot compare the refs (or a replica has not fetched the chat ref yet).
    true
  end
end
