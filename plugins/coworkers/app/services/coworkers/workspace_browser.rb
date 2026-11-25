class Coworkers::WorkspaceBrowser
  MAX_FILES = 1_000
  PAGE_SIZE = 100
  MAX_SEARCH_FILES = 250
  MAX_HISTORY_COMMITS = 25
  MAX_FILE_BYTES = 256.kilobytes
  SNIPPET_CHARACTERS = 240

  class InvalidCursor < StandardError; end

  def initialize(coworker:, repository:, user:)
    @coworker = coworker
    @repository = repository
    @reader = Syrus::Host::ContentReader.for(repository, user: user)
  end

  def call(path: nil, filters: {})
    home = @reader.resolve(home_branch)
    entries, partial = workspace_entries(home)
    selected = selected_file(home, entries, path)
    result = search(home, entries.select(&:file?), filters)
    {
      remote: @repository.remote_url,
      branch: home_branch,
      files: entries.map { |entry| entry_json(entry) },
      results: result[:results],
      page_start: result[:page_start],
      page_end: result[:page_end],
      previous_cursor: result[:previous_cursor],
      next_cursor: result[:next_cursor],
      total: result[:total],
      incomplete_reasons: result[:incomplete_reasons] + (partial ? [ "tree_limit" ] : []),
      partial: partial || result[:incomplete_reasons].any?,
      selected_file: selected,
      commits: commits(home),
      conflicts: active_conflicts(home),
      branch_counts: branch_counts
    }
  end

  private

  def home_branch = "coworkers/#{@coworker.handle}"

  def branch_counts
    remote = Coworkers::RemoteWorkspace.for_coworker(@coworker)
    remote.branch_counts(coworker: @coworker, guard: Coworkers::PushGuard.new(coworker: @coworker))
  rescue StandardError => error
    Rails.logger.warn("[Coworkers::WorkspaceBrowser] branch counts unavailable: #{Syrus::Host::GitRunner.redact(error.message)}")
    { home: nil, chat: nil, run: nil }
  end

  def workspace_entries(revision)
    entries = @reader.tree(revision).sort_by(&:path)
    [ entries.first(MAX_FILES), entries.size > MAX_FILES ]
  rescue Syrus::Host::ContentTruncated => error
    [ Array(error.partial).sort_by(&:path).first(MAX_FILES), true ]
  end

  def entry_json(entry)
    { path: entry.path, type: entry.type, size: entry.size, extension: File.extname(entry.path).delete_prefix(".").downcase,
      area: entry.path.split("/").first }
  end

  def search(revision, entries, filters)
    query = filters[:search].to_s.strip
    filtered = entries.select { |entry| metadata_match?(entry, filters) }
    candidate_count = filtered.size
    needs_contents = query.present? || filters[:content_kind].present?
    needs_history = filters[:modified_after].present? || filters[:modified_before].present? || filters[:sort] == "modified"
    searchable = filtered.first(MAX_SEARCH_FILES)
    batch = if needs_contents || needs_history
      @reader.workspace_files(revision, paths: searchable.map(&:path), max_bytes: MAX_FILE_BYTES,
        last_modified: needs_history, history_limit: MAX_HISTORY_COMMITS)
    else
      { blobs: {}, last_modified: {}, history_incomplete: false }
    end
    modified = batch[:last_modified]
    filtered.select! { |entry| modified_match?(modified[entry.path], filters) }
    incomplete = batch[:history_incomplete] ? [ "history_limit" ] : []
    incomplete << "search_limit" if (needs_contents || needs_history) && candidate_count > MAX_SEARCH_FILES
    incomplete << "content_limit" if needs_contents && batch[:blobs].values.any?(&:truncated)
    if needs_contents
      filtered = filtered.first(MAX_SEARCH_FILES).filter_map { |entry| search_result(entry, batch[:blobs][entry.path], query, modified[entry.path], filters[:content_kind]) }
    else
      filtered = filtered.map { |entry| entry_json(entry).merge(last_modified_at: modified[entry.path]&.iso8601, snippet: nil, highlights: []) }
    end
    filtered = sort_results(filtered, filters[:sort])
    offset = decode_cursor(filters[:cursor])
    page = filtered.slice(offset, PAGE_SIZE) || []
    previous_offset = [ offset - PAGE_SIZE, 0 ].max
    previous_cursor = offset.positive? ? encode_cursor(previous_offset) : nil
    next_cursor = offset + PAGE_SIZE < filtered.size ? Base64.urlsafe_encode64((offset + PAGE_SIZE).to_s, padding: false) : nil
    { results: page, total: filtered.size, page_start: page.empty? ? 0 : offset + 1, page_end: offset + page.size,
      previous_cursor:, next_cursor:, incomplete_reasons: incomplete.uniq }
  end

  def metadata_match?(entry, filters)
    path = entry.path
    extension = filters[:extension].to_s.delete_prefix(".").downcase
    prefix = filters[:path_prefix].to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
    folder = filters[:folder].to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
    filename = File.basename(path)
    return false if extension.present? && File.extname(path).delete_prefix(".").downcase != extension
    return false if prefix.present? && path != prefix && !path.start_with?("#{prefix}/")
    return false if folder.present? && File.dirname(path) != folder
    return false if filters[:filename].present? && !filename.downcase.include?(filters[:filename].to_s.downcase)
    return false if filters[:filename_exact].present? && filename.downcase != filters[:filename_exact].to_s.downcase
    return false if filters[:area].present? && path.split("/").first != filters[:area]
    return false if filters[:min_size].present? && entry.size.to_i < filters[:min_size].to_i
    return false if filters[:max_size].present? && entry.size.to_i > filters[:max_size].to_i
    true
  end

  def search_result(entry, blob, query, modified_at, content_kind)
    return unless blob

    filename_match = query.blank? || entry.path.downcase.include?(query.downcase)
    binary = blob.bytes.include?("\0")
    return if content_kind == "binary" && !binary
    return if content_kind == "text" && binary
    return if binary && !filename_match
    match = Regexp.new(Regexp.escape(query), Regexp::IGNORECASE).match(blob.text) unless binary || query.blank?
    index = match&.begin(0)
    return unless filename_match || match

    start = [ (index || 0) - (SNIPPET_CHARACTERS / 2), 0 ].max
    snippet = binary ? nil : blob.text.slice(start, SNIPPET_CHARACTERS)
    highlight_start = index && utf16_length(snippet.slice(0, index - start))
    match_text = match && blob.text.slice(match.begin(0)...match.end(0))
    entry_json(entry).merge(binary:, truncated: blob.truncated, last_modified_at: modified_at&.iso8601,
      snippet:, highlights: index ? [ { start: highlight_start, length: utf16_length(match_text) } ] : [])
  rescue Syrus::Host::ContentNotFound
    nil
  end

  def utf16_length(value)
    value.to_s.encode(Encoding::UTF_16LE).bytesize / 2
  end

  def modified_match?(value, filters)
    after = parse_time(filters[:modified_after])
    before = parse_time(filters[:modified_before])
    (!after || (value && value >= after)) && (!before || (value && value <= before))
  end

  def parse_time(value)
    Time.zone.parse(value.to_s) if value.present?
  rescue ArgumentError
    nil
  end

  def sort_results(results, sort)
    sorter = {
      "size" => -> { results.sort_by { |result| [ result[:size].to_i, result[:path].downcase ] } },
      "modified" => -> { results.sort_by { |result| [ result[:last_modified_at].to_s, result[:path].downcase ] }.reverse }
    }.fetch(sort, -> { results.sort_by { |result| result[:path].downcase } })
    sorter.call
  end

  def decode_cursor(cursor)
    return 0 if cursor.blank?
    value = Integer(Base64.urlsafe_decode64(cursor.to_s))
    raise InvalidCursor if value.negative?
    value
  rescue ArgumentError
    raise InvalidCursor, "Workspace cursor is invalid"
  end

  def encode_cursor(offset)
    Base64.urlsafe_encode64(offset.to_s, padding: false)
  end

  def selected_file(revision, entries, requested_path)
    path = requested_path.presence
    return unless path && entries.any? { |entry| entry.file? && entry.path == path }

    blob = @reader.read(revision, path, max_bytes: MAX_FILE_BYTES)
    binary = blob.bytes.include?("\0")
    { path: path, content: binary ? "" : blob.text, truncated: blob.truncated, binary: binary }
  rescue Syrus::Host::ContentNotFound
    nil
  end

  def commits(home)
    history = @reader.commits(revision: home, limit: 50)
    runs_by_sha = source_runs(history)
    history.map do |commit|
      chat_id = commit.message[/\bchat (\d+)\b/i, 1]
      run = runs_by_sha[commit.sha]
      {
        sha: commit.sha, message: commit.message, authored_at: commit.authored_at,
        source: chat_id ? "chat" : run ? "run" : "unattributed",
        source_id: chat_id&.to_i || run&.id
      }
    end
  rescue Syrus::Host::ContentError
    []
  end

  def source_runs(commits)
    shas = commits.map(&:sha)
    candidates = Syrus::Host::RunRecord.joins(:job)
      .where(user_id: @coworker.owner_user_id, jobs: { repository_id: @repository.id })
      .where(head_sha: shas + shas.map { |sha| sha.first(12) })
      .where.not(head_sha: [ nil, "" ])
      .order(id: :desc)
      .to_a

    commits.to_h do |commit|
      run = candidates.find { |candidate| commit.sha.start_with?(candidate.head_sha) }
      [ commit.sha, run ]
    end
  end

  def active_conflicts(home)
    conflict_records.filter_map do |record|
      branch = record["branch"].to_s
      next unless branch.match?(%r{\Acoworkers/(?:chat|run)/}) && conflict_active?(home, branch)

      { branch: branch, files: Array(record["files"]), detail: record["detail"] }
    end.uniq { |record| record[:branch] }
  end

  def conflict_records
    chat_ids = @coworker.coworker_chats.select(:chat_session_id)
    @coworker.chat_agents.select(:chat_session_id).then { |rostered| chat_ids = Syrus::Host::ChatSessionRecord.where(id: chat_ids).or(Syrus::Host::ChatSessionRecord.where(id: rostered)).select(:id) }
    Coworkers::WorkspaceConflict.unresolved.where(chat_session_id: chat_ids, repository: @repository).order(created_at: :desc).map do |conflict|
      { "branch" => conflict.source_branch, "files" => conflict.files, "detail" => conflict.detail }
    end
  end

  def conflict_active?(home, branch)
    chat = @reader.resolve(branch)
    !%i[identical behind].include?(@reader.relation(base: home, head: chat))
  rescue Syrus::Host::ContentUnknownRevision
    false
  rescue Syrus::Host::ContentError
    true
  end
end
