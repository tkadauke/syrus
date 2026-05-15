class EpicMarkerParser
  MARKER_PATTERN = /(?<![A-Za-z0-9_])epic\s*:\s*(?<value>[^\r\n]*)/i

  REFERENCE_PATTERN = /\A(?:(?<owner>[A-Za-z0-9][A-Za-z0-9._-]*)\/(?<repo>[A-Za-z0-9][A-Za-z0-9._-]*))?\#(?<number>\d+)\z/

  def self.parse(text:, default_repository:)
    new(text: text, default_repository: default_repository).parse
  end

  def initialize(text:, default_repository:)
    @text = text.to_s
    @default_repository = default_repository
  end

  def parse
    match = @text.match(MARKER_PATTERN)
    return nil unless match

    value = match[:value].strip
    return nil if value.blank?

    reference = value.match(REFERENCE_PATTERN)
    return child_of_epic(reference) if reference

    return nil if malformed_reference?(value)

    { kind: :epic_declaration, name: value }
  end

  private

  def child_of_epic(reference)
    {
      kind: :child_of_epic,
      owner: reference[:owner].presence || @default_repository.owner,
      repo: reference[:repo].presence || @default_repository.name,
      number: reference[:number].to_i
    }
  end

  def malformed_reference?(value)
    value.match?(/\A\d+\z/) || value.include?("#")
  end
end
