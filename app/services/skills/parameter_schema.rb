require "set"

module Skills
  # A skill's parameter schema is an array of { key:, type:, required:,
  # label:, ... } entries — the same shape as
  # InputSources::Linear#config_schema (plugins/linear_source/app/models/
  # input_sources/linear.rb). Declared either in a repo-local SKILL.md's
  # frontmatter or by a built-in skill class's `parameter_schema`. Later
  # Jobs in this Epic use `normalize` to render a launch form and
  # `validate!` to check ScheduledTask/slash-command args against it.
  module ParameterSchema
    VALID_TYPES = %w[string text boolean integer select].freeze

    Field = Data.define(:key, :type, :required, :label, :options, :default, :depends_on)

    ParseError = Class.new(StandardError)
    ValidationError = Class.new(StandardError)

    module_function

    def normalize(raw)
      raise ParseError, "parameters: must be an array" unless raw.is_a?(Array)

      seen = Set.new
      raw.each_with_index.map { |item, index| normalize_field(item, index, seen) }
    end

    def normalize_field(raw, index, seen)
      label = "parameters[#{index}]"
      raise ParseError, "#{label}: must be a mapping" unless raw.is_a?(Hash)

      raw = raw.stringify_keys
      key = raw["key"].to_s.strip
      raise ParseError, "#{label}.key: is required" if key.empty?
      raise ParseError, "#{label}.key: #{key.inspect} is duplicated" if seen.include?(key)
      seen << key

      type = raw["type"].to_s.strip
      raise ParseError, "#{label}.type: must be one of #{VALID_TYPES.join(', ')}" unless VALID_TYPES.include?(type)

      options = raw["options"]
      if type == "select"
        raise ParseError, "#{label}.options: is required for type=select" if options.blank?
        options = Array(options).map(&:to_s)
      else
        options = nil
      end

      Field.new(
        key: key,
        type: type,
        required: raw.key?("required") ? ActiveModel::Type::Boolean.new.cast(raw["required"]) : false,
        label: raw["label"].to_s.strip.presence || key.tr("_", " ").capitalize,
        options: options,
        default: raw["default"],
        depends_on: raw["depends_on"].to_s.strip.presence
      )
    end

    # Validates a submitted params hash (e.g. from a ScheduledTask fire or
    # a slash-command invocation) against a normalized parameter schema
    # (an array of Field, as returned by `normalize`). Raises
    # ValidationError describing every problem found rather than just the
    # first, so a caller can surface a complete list to the operator.
    def validate!(fields, params)
      params = (params || {}).stringify_keys
      errors = []

      fields.each do |field|
        value = params[field.key]
        errors << "#{field.key}: is required" if field.required && value.blank? && field.default.nil?

        if field.type == "select" && value.present? && !field.options.include?(value.to_s)
          errors << "#{field.key}: must be one of #{field.options.join(', ')}"
        end
      end

      known_keys = fields.map(&:key)
      (params.keys - known_keys).each { |unknown| errors << "#{unknown}: is not a declared parameter" }

      raise ValidationError, errors.join("; ") if errors.any?

      true
    end
  end
end
