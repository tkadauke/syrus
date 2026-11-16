class PluginCliCommands
  ValidationError = Class.new(StandardError)
  HandlerError = Class.new(StandardError)
  VALUE_COERCERS = {
    "string" => ->(value, _) { value.to_s },
    "boolean" => lambda do |value, _|
      next value if value == true || value == false
      next true if value.to_s == "true"
      next false if value.to_s == "false"
      raise ValidationError, :argument_invalid
    end,
    "integer" => ->(value, _) { Integer(value) },
    "enum" => lambda do |value, declaration|
      value.to_s.tap { |item| raise ValidationError, :argument_invalid unless declaration.fetch("values").include?(item) }
    end,
    "repeatable_string" => ->(value, _) { Array(value).map(&:to_s) }
  }.freeze

  def self.catalog
    health = Syrus::PluginRegistry.health
    Syrus::PluginRegistry.all_plugins.select { |manifest| manifest.enabled? && health.healthy?(manifest.name) }.sort_by(&:name).flat_map do |manifest|
      manifest.cli_commands.sort_by { |command| command.fetch("path") }.map do |command|
        command.except("handler").merge("plugin" => manifest.name)
      end
    end
  end

  def self.execute(plugin:, path:, args:, flags:, user:)
    manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == plugin }
    raise ValidationError, :plugin_unknown unless manifest
    raise ValidationError, :plugin_disabled unless manifest.enabled? && Syrus::PluginRegistry.health.healthy?(manifest.name)
    command = manifest.cli_commands.find { |candidate| candidate.fetch("path") == path.to_s.split.join(" ") }
    raise ValidationError, :command_unknown unless command

    parsed_args = validate_values(command.fetch("arguments"), args, positional: true)
    parsed_flags = validate_values(command.fetch("flags"), flags, positional: false)
    handler = command.fetch("handler").constantize.new
    result = handler.call(args: parsed_args, flags: parsed_flags, user: user)
    raise HandlerError unless result.is_a?(Syrus::Plugin::CliCommand::Result)
    result
  rescue NameError, NotImplementedError => e
    raise HandlerError, e.message
  end

  def self.validate_values(declarations, supplied, positional:)
    if positional
      raise ValidationError, :argument_invalid unless supplied.nil? || supplied.is_a?(Array)
      values = supplied || []
    else
      raise ValidationError, :argument_invalid unless supplied.is_a?(Hash) || supplied.respond_to?(:to_unsafe_h)
      values = (supplied.respond_to?(:to_unsafe_h) ? supplied.to_unsafe_h : supplied).stringify_keys
    end
    raise ValidationError, :argument_invalid if positional && values.length > declarations.length
    raise ValidationError, :argument_invalid unless positional || (values.keys - declarations.map { |entry| entry.fetch("name") }).empty?

    declarations.each_with_index.to_h do |declaration, index|
      raw = positional ? values[index] : values[declaration.fetch("name")]
      raw = declaration["default"] if raw.nil? && declaration.key?("default")
      raise ValidationError, :argument_invalid if raw.nil? && declaration.fetch("required")
      [declaration.fetch("name"), coerce(raw, declaration)]
    end.compact
  end

  def self.coerce(value, declaration)
    return nil if value.nil?
    VALUE_COERCERS.fetch(declaration.fetch("type")).call(value, declaration)
  rescue ArgumentError, TypeError
    raise ValidationError, :argument_invalid
  end
  private_class_method :validate_values, :coerce
end
