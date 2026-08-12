class JobDependencyParser
  Reference = Data.define(:owner, :repo, :number)

  MAX_LINE_BYTES = 8.kilobytes
  MAX_REFERENCES = 50

  KEYWORD_PATTERN = /\A\s*(?:depends(?:\s+|-)?on|blocked(?:\s+|-)?by)\s*:\s*(?<refs>.+)\z/i

  REFERENCE_PATTERN = /
    (?:
      (?<owner>[A-Za-z0-9][A-Za-z0-9._-]*)\/
      (?<repo>[A-Za-z0-9][A-Za-z0-9._-]*)
    )?
    \#(?<number>\d+)
  /x

  def self.parse(text:, default_repository:)
    new(text: text, default_repository: default_repository).parse
  end

  def initialize(text:, default_repository:)
    @text = text.to_s
    @default_repository = default_repository
  end

  def parse
    @text.each_line.flat_map do |line|
      match = line.chomp.safe_byteslice(0, MAX_LINE_BYTES).match(KEYWORD_PATTERN)
      next [] unless match

      match[:refs].scan(REFERENCE_PATTERN).filter_map do |owner, repo, number|
        Reference.new(
          owner: (owner.presence || @default_repository.owner),
          repo: (repo.presence || @default_repository.name),
          number: number.to_i
        )
      end
    end.uniq.first(MAX_REFERENCES)
  end
end
