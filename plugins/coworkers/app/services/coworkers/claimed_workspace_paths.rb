class Coworkers::ClaimedWorkspacePaths
  CORE_FILES = %w[AGENTS.md SOUL.md USER.md].freeze
  CODE_SPAN = /`([^`\n]+)`/
  MEMORY_PATH = %r{(?<![\w/])memory/[A-Za-z0-9_.@+-]+(?:/[A-Za-z0-9_.@+-]+)*}

  def self.from(summary)
    text = summary.to_s
    candidates = text.scan(CODE_SPAN).flatten + text.scan(MEMORY_PATH)
    candidates.filter_map { |candidate| normalize(candidate) }.uniq
  end

  def self.normalize(candidate)
    path = candidate.to_s.strip.delete_prefix("./").sub(/[.,;:]\z/, "")
    return path if CORE_FILES.include?(path)
    return unless path.start_with?("memory/")
    return if path.split("/").include?("..")

    path
  end

  private_class_method :normalize
end
