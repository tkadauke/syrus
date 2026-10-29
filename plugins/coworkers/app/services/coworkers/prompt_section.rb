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
    rendered = HEADING.dup
    paths_for(chat_session:, repository:, message:).each do |name|
      path = Syrus::PathJail.resolve!(root, name)
      next unless path.file?

      separator = rendered == HEADING ? "" : "\n\n"
      section = "### #{name}\n\n#{bounded_read(path, MAX_FILE_BYTES)}"
      candidate = rendered + separator + section
      if candidate.bytesize > MAX_TOTAL_BYTES
        rendered = truncate_aggregate(candidate)
        break
      end
      rendered = candidate
    end
    return if rendered == HEADING

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

  private_class_method :paths_for, :bounded_read, :truncate_aggregate
end
