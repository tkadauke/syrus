class DirectJobTitleGenerator
  FALLBACK_TITLE = "Direct job"
  MAX_TITLE_BYTES = 100

  def self.call(prompt)
    new(prompt).call
  end

  def initialize(prompt)
    @prompt = prompt.to_s
  end

  def call
    candidate = meaningful_lines.first
    return FALLBACK_TITLE if candidate.blank?

    truncate(clean_sentence(candidate)).presence || FALLBACK_TITLE
  end

  private

  def meaningful_lines
    @prompt.lines.filter_map do |line|
      cleaned = clean_line(line)
      cleaned.presence
    end
  end

  def clean_line(line)
    line.to_s
        .strip
        .sub(/\A```[[:alnum:]_-]*\s*\z/, "")
        .sub(/\A>+\s*/, "")
        .sub(/\A\#{1,6}\s*/, "")
        .sub(/\A(?:[-*+]|\d+[.)])\s+/, "")
        .sub(/\A\[[ xX]\]\s+/, "")
        .squish
        .then { |text| strip_wrapping_marks(text) }
  end

  def clean_sentence(text)
    sentence = text.match(/\A(.+?[.!?])(?:\s+|$)/)&.[](1) || text
    strip_wrapping_marks(sentence.squish)
  end

  def strip_wrapping_marks(text)
    result = text.to_s.strip
    loop do
      stripped = result
                 .sub(/\A[`'"]+/, "")
                 .sub(/[`'"]+\z/, "")
                 .strip
      return stripped if stripped == result

      result = stripped
    end
  end

  def truncate(text)
    return text if text.bytesize <= MAX_TITLE_BYTES

    text.safe_byteslice(0, MAX_TITLE_BYTES).strip
  end
end
