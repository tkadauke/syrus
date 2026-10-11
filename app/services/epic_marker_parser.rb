class EpicMarkerParser
  COMMENT_OPEN = "<!--"
  COMMENT_CLOSE = "-->"
  MARKER_NAME = "syrus-epic"
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
    offset = 0
    loop do
      start_index = @text.index(COMMENT_OPEN, offset)
      return nil unless start_index

      content_start = start_index + COMMENT_OPEN.length
      end_index = @text.index(COMMENT_CLOSE, content_start)
      return nil unless end_index

      content = @text[content_start...end_index].to_s
      value = marker_value_from_comment(content)
      return value if value

      offset = end_index + COMMENT_CLOSE.length
    end
  end

  def marker_value_from_comment(content)
    header, *body_lines = content.lines
    return nil unless header

    header = header.strip
    return nil unless header.downcase.start_with?(MARKER_NAME)

    rest = header[MARKER_NAME.length..].to_s
    return nil unless rest.blank? || rest.start_with?(":") || rest.match?(/\A\s/)

    inline_value = rest.lstrip.delete_prefix(":").strip
    return truncate_marker_value(inline_value) if inline_value.present?

    marker_body_value(body_lines)
  end

  def marker_body_value(body_lines)
    line = body_lines.find { |candidate| candidate.strip.present? }
    return nil unless line

    value = line.strip
    value = value.sub(/\Aepic\s*:\s*/i, "")
    truncate_marker_value(value)
  end

  def truncate_marker_value(value)
    value.safe_byteslice(0, MAX_MARKER_VALUE_BYTES).strip
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
