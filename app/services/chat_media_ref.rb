module ChatMediaRef
  # The valid kinds come from the registered media sources rather than a fixed
  # regex, so a plugin that contributes a kind is not also an edit to core.
  def self.valid?(ref)
    kind, id_str = ref.to_s.split(":", 2)
    return false unless id_str.to_s.match?(/\A\d+\z/)

    ChatMediaSources.kinds.include?(kind)
  end

  def self.split(ref)
    kind, id_str = ref.to_s.split(":", 2)
    [ kind, id_str.to_i ]
  end

  def self.expected_format
    "#{ChatMediaSources.kinds.map { |kind| "#{kind}:ID" }.join(' or ')}"
  end
end
