class TestCaseIdentity
  SEPARATOR = "\0".freeze
  UNKNOWN_SUITES = [ "", "unknown" ].freeze

  def self.for(test_case)
    attributes = attributes_for(test_case)
    name = attributes["name"].to_s.strip
    return if name.blank?

    suite_name = canonical_suite(attributes)
    [ suite_name, name ].join(SEPARATOR)
  end

  def self.canonical_suite(test_case)
    attributes = attributes_for(test_case)
    file_path = attributes["file_path"].to_s.strip.sub(%r{\A\./}, "")
    return file_path if file_path.present?

    suite_name = attributes["suite_name"].to_s.strip
    UNKNOWN_SUITES.include?(suite_name.downcase) ? "unknown" : suite_name
  end

  def self.attributes_for(test_case)
    raw = if test_case.respond_to?(:to_h)
      test_case.to_h
    elsif test_case.respond_to?(:attributes)
      test_case.attributes
    else
      {
        "suite_name" => (test_case.suite_name if test_case.respond_to?(:suite_name)),
        "name" => (test_case.name if test_case.respond_to?(:name)),
        "file_path" => (test_case.file_path if test_case.respond_to?(:file_path))
      }
    end
    raw.to_h.stringify_keys
  end
  private_class_method :attributes_for
end
