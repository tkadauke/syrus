class Coworkers::PromptSection
  IDENTITY_FILES = %w[SOUL.md AGENTS.md USER.md].freeze
  FILES = IDENTITY_FILES
  MAX_FILE_BYTES = Coworkers::WorkspaceFileReadPolicy::MAX_BYTES
  MAX_TOTAL_BYTES = 128.kilobytes
  TRUNCATION_MARKER = Coworkers::WorkspaceFileReadPolicy::TRUNCATION_MARKER
  HEADING = "## Coworker identity and standing context\n\n".freeze

  def self.chat_prompt_section(chat_session:, repository:, message: nil)
    coworker = chat_session.respond_to?(:coworker) ? chat_session.coworker : nil
    return unless coworker.respond_to?(:kind) && coworker.kind == "coworker"
    return unless repository

    root = ChatWorkspace.repo_path_for(chat_session, repository)
    rendered = HEADING + grant_section(coworker)
    rendered << conflict_section(chat_session:, repository:, root:)
    rendered = truncate_aggregate(rendered) if rendered.bytesize > MAX_TOTAL_BYTES
    paths_for(chat_session:, repository:, message:).each do |name|
      content = safe_workspace_read(root, name)
      next unless content

      separator = rendered == HEADING ? "" : "\n\n"
      section = "### #{name}\n\n#{current_memory(content)}"
      candidate = rendered + separator + section
      if candidate.bytesize > MAX_TOTAL_BYTES
        rendered = truncate_aggregate(candidate)
        break
      end
      rendered = candidate
    end
    rendered
  end

  def self.paths_for(chat_session:, repository:, message:)
    dates = [ Time.zone.today, Time.zone.yesterday ]
    people = (chat_session.participants.to_a + [ message&.sender_user ]).compact.filter_map(&:handle).uniq

    IDENTITY_FILES +
      dates.map { |date| "memory/daily/#{date.iso8601}.md" } +
      people.map { |handle| "memory/people/#{handle}.md" } +
      [ "memory/repos/#{repository.owner}__#{repository.name}.md" ]
  end

  def self.bounded_read(path, limit)
    truncated = path.size > limit
    marker = "\n\n#{TRUNCATION_MARKER}\n"
    content_limit = truncated ? [ limit - marker.bytesize, 0 ].max : limit
    raw = File.binread(path, content_limit) || +""
    content = raw.dup.force_encoding(Encoding::UTF_8).scrub.safe_byteslice(0, content_limit)
    truncated ? content + marker.byteslice(0, limit - content.bytesize) : content
  end

  def self.truncate_aggregate(content)
    suffix = "\n\n#{TRUNCATION_MARKER}"
    content.safe_byteslice(0, MAX_TOTAL_BYTES - suffix.bytesize) + suffix
  end

  # Superseded entries remain readable in the workspace and Memory tab, but
  # are omitted from standing prompt context so an old decision cannot compete
  # with its replacement.
  def self.current_memory(content)
    content.lines.reject { |line| line.match?(/~~.+~~ \(superseded \d{4}-\d{2}-\d{2} by .+: .+\)/) }.join
  end

  # Superseded entries remain readable in the workspace and Memory tab, but
  # are omitted from standing prompt context so an old decision cannot compete
  # with its replacement.
  def self.current_memory(content)
    content.lines.reject { |line| line.match?(/~~.+~~ \(superseded \d{4}-\d{2}-\d{2} by .+: .+\)/) }.join
  end

  def self.grant_section(coworker)
    held = coworker.permission_rules.entries.index_by { |entry| entry.fetch(:capability) }
    lines = Coworkers::GrantCatalog.all.sort_by(&:name).map do |descriptor|
      grant = held[descriptor.name]
      tools = descriptor.tools.presence&.join(", ") || "no tools currently registered"
      availability = Coworkers::PrivilegedGrantGate.availability(descriptor)
      if !availability.available?
        "- `#{descriptor.name}` — unavailable (#{availability.reason}); tools withheld"
      elsif grant && grant[:approval_policy] != "off"
        scope = grant[:scope].nil? ? "" : "; scope: #{descriptor.scope_label(grant[:scope])}"
        "- `#{descriptor.name}` — #{grant[:approval_policy]} by canonical permission rule#{scope}; tools: #{tools}"
      else
        "- `#{descriptor.name}` — not held; unlocks: #{tools}"
      end
    end
    code_access = held["code.read"]
    repository_line = if code_access && code_access[:approval_policy] != "off"
      descriptor = Coworkers::GrantCatalog.fetch("code.read")
      "You may read #{descriptor.scope_label(code_access[:scope])}. You may propose Jobs to change those repositories, but never edit their code."
    else
      "You cannot read product repositories unless your owner grants `code.read`. You may propose Jobs, but never edit product code."
    end
    "### Permissions\n\n#{repository_line}\n\nCanonical permission rules determine whether tools run automatically, ask first, or are denied. If a needed capability is blocked, request that permission from your owner.\n\n#{lines.join("\n")}"
  end

  def self.conflict_section(chat_session:, repository:, root:)
    conflict = Coworkers::WorkspaceConflict.active.find_by(chat_session:, repository:)
    return "" unless conflict

    files = Array(conflict.files)
    contexts = files.filter_map do |relative|
      preserved = conflict.versions.to_h[relative].presence
      content = preserved || safe_conflict_read(root, relative)
      next unless content
      "#### #{relative}\n\n```diff\n#{content}\n```"
    end
    <<~TEXT


      ### Private workspace conflict recovery

      Reconcile the files below without mentioning the conflict to the owner. Preserve the intent of both sides; do not discard either side. Remove every conflict marker and leave the files in their intended final form. Syrus will privately validate and retry persistence. A durable recovery ref is #{conflict.recovery_ref.presence || conflict.source_branch}.

      Affected files: #{files.join(", ")}

      #{contexts.join("\n\n")}
    TEXT
  end

  def self.safe_conflict_read(root, relative)
    candidate = Syrus::PathJail.resolve!(root, relative)
    return if candidate.symlink? || !candidate.file?

    path = Syrus::PathJail.resolve!(root, relative, resolve_symlinks: true)
    bounded_read(path, MAX_FILE_BYTES)
  rescue Syrus::PathJail::PathEscape
    nil
  end

  def self.safe_workspace_read(root, relative)
    path = Syrus::PathJail.resolve!(root, relative, resolve_symlinks: true)
    return unless path.file?

    bounded_read(path, MAX_FILE_BYTES)
  rescue Syrus::PathJail::PathEscape
    nil
  end

  private_class_method :paths_for, :bounded_read, :truncate_aggregate, :current_memory, :grant_section, :conflict_section,
    :safe_conflict_read, :safe_workspace_read
end
