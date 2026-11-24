class Coworkers::ClaimedWorkspacePaths
  CORE_FILES = %w[AGENTS.md SOUL.md USER.md].freeze
  CODE_SPAN = /`([^`\n]+)`/
  MEMORY_PATH = %r{(?<![\w/])memory/[A-Za-z0-9_.@+-]+(?:/[A-Za-z0-9_.@+-]+)*}
  WRITE_VERB = /(?:wrote|written|write|created?|updated?|edited?|modified?|saved?|added?|persisted?|recorded?|generated?)/i
  DELETE_VERB = /(?:deleted?|removed?)/i
  NEGATED_WRITE = /(?:did|do|does|was|were|is|are|have|has|had)\s+not\s+#{WRITE_VERB}/i
  OPERATION = /(?<negative>#{NEGATED_WRITE})|(?<delete>#{DELETE_VERB})|(?<write>#{WRITE_VERB})/i
  SENTENCE_BOUNDARY = /[.!?](?:\s+|\z)/

  def self.from(summary)
    text = summary.to_s
    candidates = text.to_enum(:scan, /#{CODE_SPAN}|#{MEMORY_PATH}/).map do
      match = Regexp.last_match
      [ match[1] || match[0], match.begin(0) ]
    end
    candidates.filter_map do |candidate, offset|
      path = normalize(candidate)
      path if path && write_claim?(text, offset)
    end.uniq
  end

  # Directory-level or wildcard memory claims ("saved to `memory/`",
  # "updated memory/people/*"). These can never be verified as an exact file
  # write, so they are reported separately and treated as invalid claims.
  VAGUE_PATH = %r{(?<![\w/])memory(?:/[A-Za-z0-9_.@+*?-]+)*(?:/\*{0,2}|/?\*[A-Za-z0-9_.*?-]*)?(?![\w.@+-])}

  def self.unsupported_from(summary)
    text = summary.to_s
    candidates = text.to_enum(:scan, /#{CODE_SPAN}|#{VAGUE_PATH}/).map do
      match = Regexp.last_match
      [ match[1] || match[0], match.begin(0) ]
    end
    candidates.filter_map do |candidate, offset|
      path = candidate.to_s.strip.delete_prefix("./").sub(/[.,;:]\z/, "")
      next unless path == "memory" || path.start_with?("memory/")
      next if path.split("/").include?("..")
      next unless path.end_with?("/") || path.include?("*") || path == "memory"
      path if write_claim?(text, offset)
    end.uniq
  end

  def self.normalize(candidate)
    path = candidate.to_s.strip.delete_prefix("./").sub(/[.,;:]\z/, "")
    return path if CORE_FILES.include?(path)
    return unless path.start_with?("memory/")
    return if path.split("/").include?("..")

    path
  end

  def self.write_claim?(text, offset)
    prefix = text[0...offset]
    context = prefix.split(SENTENCE_BOUNDARY).last.to_s
    operation = context.to_enum(:scan, OPERATION).map { Regexp.last_match }.last
    operation && operation[:write].present?
  end

  private_class_method :normalize, :write_claim?
end
