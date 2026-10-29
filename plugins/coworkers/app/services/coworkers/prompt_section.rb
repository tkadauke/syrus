class Coworkers::PromptSection
  IDENTITY_FILES = %w[SOUL.md AGENTS.md USER.md].freeze
  FILES = IDENTITY_FILES
  MAX_FILE_BYTES = 64.kilobytes
  MAX_TOTAL_BYTES = 128.kilobytes
  TRUNCATION_MARKER = "[truncated at the coworker memory cap]".freeze

  def self.chat_prompt_section(chat_session:, repository:, message: nil)
    coworker = chat_session.respond_to?(:coworker) ? chat_session.coworker : nil
    return unless coworker.respond_to?(:kind) && coworker.kind == "coworker"
    return unless repository

    root = ChatWorkspace.repo_path_for(chat_session, repository)
    remaining = MAX_TOTAL_BYTES
    sections = []
    paths_for(chat_session:, repository:, message:).each do |name|
      if remaining <= 0
        sections << TRUNCATION_MARKER
        break
      end

      path = Syrus::PathJail.resolve!(root, name)
      next unless path.file?

      content = bounded_read(path, [ MAX_FILE_BYTES, remaining ].min)
      remaining -= content.bytesize
      sections << "### #{name}\n\n#{content}"
    end
    return if sections.empty?

    "## Coworker identity and standing context\n\n#{sections.join("\n\n")}"
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
    content = File.binread(path, content_limit).to_s.force_encoding(Encoding::UTF_8).scrub.safe_byteslice(0, content_limit)
    truncated ? content + marker.byteslice(0, limit - content.bytesize) : content
  end

  private_class_method :paths_for, :bounded_read
end
