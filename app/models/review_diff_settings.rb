class ReviewDiffSettings
  DEFAULTS = {
    "line_wrapping" => "scroll",
    "desktop_view" => "unified",
    "syntax_highlighting" => true,
    "intraline_highlighting" => "word",
    "whitespace" => "show",
    "visible_whitespace" => false,
    "tab_width" => 2,
    "context_lines" => 20,
    "density" => "comfortable",
    "line_numbers" => true,
    "file_list" => true,
    "file_list_layout" => "flat",
    "file_sort" => "original"
  }.freeze

  VALUES = {
    "line_wrapping" => %w[wrap scroll],
    "desktop_view" => %w[unified split],
    "intraline_highlighting" => %w[word off],
    "whitespace" => %w[show trim_trailing],
    "density" => %w[compact comfortable spacious],
    "file_list_layout" => %w[flat nested],
    "file_sort" => %w[original alphabetical change_size]
  }.freeze
  BOOLEAN_KEYS = %w[syntax_highlighting visible_whitespace line_numbers file_list].freeze
  NUMERIC_RANGES = {
    "tab_width" => (2..8),
    "context_lines" => (5..200)
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
