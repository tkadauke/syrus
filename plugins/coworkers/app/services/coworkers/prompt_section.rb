class Coworkers::PromptSection
  FILES = %w[SOUL.md AGENTS.md USER.md].freeze
  MAX_FILE_BYTES = 64.kilobytes
  MAX_TOTAL_BYTES = 128.kilobytes

  def self.chat_prompt_section(chat_session:, repository:)
    coworker = chat_session.respond_to?(:coworker) ? chat_session.coworker : nil
    return unless coworker.respond_to?(:kind) && coworker.kind == "coworker"
    return unless repository

    root = ChatWorkspace.repo_path_for(chat_session, repository)
    remaining = MAX_TOTAL_BYTES
    sections = []
    FILES.each do |name|
      break if remaining <= 0

      path = Syrus::PathJail.resolve!(root, name)
      next unless path.file?

      content = File.binread(path, [ MAX_FILE_BYTES, remaining ].min).to_s.force_encoding(Encoding::UTF_8).scrub
      remaining -= content.bytesize
      sections << "### #{name}\n\n#{content}"
    end
    return if sections.empty?

    "## Coworker identity and standing context\n\n#{sections.join("\n\n")}"
  end
end
