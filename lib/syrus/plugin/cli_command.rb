module Syrus
  module Plugin
    module CliCommand
      TYPES = %w[string boolean integer enum repeatable_string].freeze
      PATH_PATTERN = /\A[a-z0-9][a-z0-9_-]*(?: [a-z0-9][a-z0-9_-]*)*\z/

      class InvalidArguments < StandardError; end

      class Result
        def self.table(columns:, rows:) = TableResult.new(columns:, rows:)
        def self.text(text:) = TextResult.new(text:)
        def self.json(value:) = JsonResult.new(value:)
      end

      TableResult = Data.define(:columns, :rows) do
        def as_json(*) = { kind: "table", columns: columns, rows: rows }
      end
      TextResult = Data.define(:text) do
        def as_json(*) = { kind: "text", text: text }
      end
      JsonResult = Data.define(:value) do
        def as_json(*) = { kind: "json", value: value }
      end

      def call(args:, flags:, user:)
        raise NotImplementedError, "#{self.class.name} must implement #call"
      end

      class << self
        def normalize(entries)
          commands = []
          errors = []

          Array(entries).each_with_index do |entry, index|
            command, command_errors = normalize_command(entry, index)
            commands << command if command
            errors.concat(command_errors)
          end

          commands.group_by { |command| command.fetch("path") }.each do |path, duplicates|
            errors << "duplicate CLI command path #{path.inspect}" if duplicates.many?
          end

          [ commands.freeze, errors.freeze ]
        end

        private

        def normalize_command(entry, index)
          attrs = entry.to_h.stringify_keys
          path = attrs["path"].to_s.strip.gsub(/\s+/, " ")
          summary = attrs["summary"].to_s.strip
          handler = attrs["handler"].to_s.strip
          errors = []
          errors << "CLI command #{index + 1} has an invalid path" unless PATH_PATTERN.match?(path)
          errors << "CLI command #{path.inspect} requires a one-line summary" if summary.blank? || summary.include?("\n")
          errors << "CLI command #{path.inspect} is missing handler" if handler.blank?

          arguments, argument_errors = normalize_parameters(attrs["arguments"], path:, flags: false)
          flags, flag_errors = normalize_parameters(attrs["flags"], path:, flags: true)
          errors.concat(argument_errors).concat(flag_errors)
          names = arguments.map { |item| item.fetch("name") } + flags.map { |item| item.fetch("name") }
          errors << "CLI command #{path.inspect} has duplicate argument or flag names" if names.uniq.length != names.length

          command = { "path" => path, "summary" => summary, "handler" => handler,
                      "arguments" => arguments, "flags" => flags }.freeze
          [ command, errors ]
        rescue NoMethodError, TypeError
          [ nil, [ "CLI command #{index + 1} must be an object" ] ]
        end

        def normalize_parameters(entries, path:, flags:)
          errors = []
          normalized = Array(entries).each_with_index.map do |entry, index|
            attrs = entry.to_h.stringify_keys
            name = attrs["name"].to_s
            type = attrs["type"].to_s
            label = flags ? "flag" : "argument"
            errors << "CLI command #{path.inspect} #{label} #{index + 1} has an invalid name" unless name.match?(/\A[a-z][a-z0-9_-]*\z/)
            errors << "CLI command #{path.inspect} #{label} #{name.inspect} has bad type #{type.inspect}" unless TYPES.include?(type)
            errors << "CLI command #{path.inspect} #{label} #{name.inspect} required must be boolean" if attrs.key?("required") && ![ true, false ].include?(attrs["required"])
            values = Array(attrs["values"])
            errors << "CLI command #{path.inspect} enum #{name.inspect} requires values" if type == "enum" && values.empty?
            if attrs.key?("default") && !valid_default?(type, attrs["default"], values)
              errors << "CLI command #{path.inspect} #{label} #{name.inspect} has an invalid default"
            end
            attrs.slice("name", "type", "required", "default", "values").compact
          rescue NoMethodError, TypeError
            errors << "CLI command #{path.inspect} #{label} #{index + 1} must be an object"
            {}
          end
          [ normalized.freeze, errors ]
        end

        def valid_default?(type, value, enum_values)
          validators = {
            "string" => -> { value.is_a?(String) },
            "boolean" => -> { value == true || value == false },
            "integer" => -> { value.is_a?(Integer) },
            "enum" => -> { enum_values.map(&:to_s).include?(value.to_s) },
            "repeatable_string" => -> { value.is_a?(Array) && value.all? { |item| item.is_a?(String) } }
          }
          validators.fetch(type, -> { true }).call
        end
      end
    end
  end
end
