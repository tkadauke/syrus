class ReviewDiffSettings
  DEFAULTS = {
    "line_wrapping" => "scroll",
    "desktop_view" => "unified",
    "syntax_highlighting" => true,
    "intraline_highlighting" => "word",
    "whitespace" => "show",
    "tab_width" => 2,
    "density" => "comfortable",
    "line_numbers" => true,
    "file_list" => true
  }.freeze

  VALUES = {
    "line_wrapping" => %w[wrap scroll],
    "desktop_view" => %w[unified split],
    "intraline_highlighting" => %w[word off],
    "whitespace" => %w[show trim_trailing],
    "density" => %w[compact comfortable spacious]
  }.freeze
  BOOLEAN_KEYS = %w[syntax_highlighting line_numbers file_list].freeze
  NUMERIC_RANGES = {
    "tab_width" => (2..8)
  }.freeze

  def self.normalize(value)
    return DEFAULTS.dup unless value.is_a?(Hash)

    DEFAULTS.merge(value.each_with_object({}) do |(key, setting), hash|
      normalized_key = key.to_s
      if (values = VALUES[normalized_key])
        normalized_value = setting.to_s
        hash[normalized_key] = normalized_value if values.include?(normalized_value)
      elsif BOOLEAN_KEYS.include?(normalized_key)
        hash[normalized_key] = ActiveModel::Type::Boolean.new.cast(setting)
      elsif (range = NUMERIC_RANGES[normalized_key])
        normalized_value = setting.to_i
        hash[normalized_key] = normalized_value if range.cover?(normalized_value)
      end
    end)
  end

  def self.permitted_keys
    DEFAULTS.keys
  end
end
