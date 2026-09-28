class EpicMarkerParser
  REFERENCE_PATTERN = /\A(?:(?<owner>[A-Za-z0-9][A-Za-z0-9._-]*)\/(?<repo>[A-Za-z0-9][A-Za-z0-9._-]*))?\#?(?<number>\d+)\z/
  MAX_MARKER_VALUE_BYTES = 2.kilobytes

  def self.parse(text:, default_repository:)
    new(text: text, default_repository: default_repository).parse
  end

  def initialize(text:, default_repository:)
    @text = text.to_s
    @default_repository = default_repository
  end

  def parse
    value = marker_value
    return nil unless value

    return nil if value.blank?

    reference = value.match(REFERENCE_PATTERN)
    return child_of_epic(reference) if reference

    return nil if malformed_reference?(value)

    { kind: :epic_declaration, name: value }
  end

  private

  def marker_value
    @text.each_line do |line|
      index = line.downcase.index("epic")
      next unless index
      next if index.positive? && line[index - 1].match?(/[A-Za-z0-9_]/)

      after_marker = line.byteslice(index + 4, MAX_MARKER_VALUE_BYTES + 16).to_s
      colon_index = after_marker.index(":")
      next unless colon_index && after_marker[0...colon_index].strip.empty?

      return after_marker[(colon_index + 1)..].to_s.strip.safe_byteslice(0, MAX_MARKER_VALUE_BYTES).strip
    end

    nil
  end

  def child_of_epic(reference)
    {
      kind: :child_of_epic,
      owner: reference[:owner].presence || @default_repository.owner,
      repo: reference[:repo].presence || @default_repository.name,
      number: reference[:number].to_i
    }
  end

  def malformed_reference?(value)
    value.include?("#")
  end
end
