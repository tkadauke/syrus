# frozen_string_literal: true

module Syrus
  module Plugin
    # Validates and normalizes the manifest-owned description of a server-side
    # CLI command. Handler constants deliberately remain strings until execute.
    class CliCommand
      PATH_SEGMENT = /\A[a-z][a-z0-9_-]*\z/

      class ValueType
        def coerce(value) = value
      end

      class StringType < ValueType
        def coerce(value) = value.to_s
      end

      class BooleanType < ValueType
        TRUE_VALUES = [ true, "true", "1" ].freeze
        FALSE_VALUES = [ false, "false", "0" ].freeze

        def coerce(value)
          return true if TRUE_VALUES.include?(value)
          return false if FALSE_VALUES.include?(value)

          raise ArgumentError
        end
      end

      class IntegerType < ValueType
        def coerce(value) = value.is_a?(Integer) ? value : Integer(value, 10)
      end

      class EnumType < StringType
        def initialize(values) = @values = values

        def coerce(value)
          super.tap { |coerced| raise ArgumentError unless @values.include?(coerced) }
        end
      end

      class RepeatableStringType < ValueType
        def coerce(value) = Array(value).map(&:to_s)
      end

      TYPE_BUILDERS = {
        "string" => ->(_entry) { StringType.new },
        "boolean" => ->(_entry) { BooleanType.new },
        "integer" => ->(_entry) { IntegerType.new },
        "enum" => ->(entry) { EnumType.new(entry.fetch("values")) },
        "repeatable_string" => ->(_entry) { RepeatableStringType.new }
      }.freeze

      class << self
        def normalize_all(plugin_name, declarations)
          commands = []
          errors = []
          Array(declarations).each_with_index do |declaration, index|
            commands << normalize(declaration)
          rescue StandardError => e
            errors << "cli_commands[#{index}]: #{e.message}"
          end

          duplicates = commands.group_by { |command| command.fetch("path") }.select { |_path, entries| entries.many? }.keys
          duplicates.each { |path| errors << "duplicate CLI command path #{path.inspect}" }
          [ commands.reject { |command| duplicates.include?(command.fetch("path")) }, errors.map { |error| "#{plugin_name}: #{error}" } ]
        end

        def normalize(declaration)
          entry = declaration.to_h.stringify_keys
          path = Array(entry.fetch("path")).flat_map { |part| part.to_s.split }.reject(&:blank?)
          raise ArgumentError, "path must contain valid command segments" if path.empty? || path.any? { |part| !PATH_SEGMENT.match?(part) }

          summary = entry.fetch("summary").to_s.strip
          raise ArgumentError, "summary must be one non-empty line" if summary.empty? || summary.include?("\n")

          handler = entry.fetch("handler").to_s
          raise ArgumentError, "handler must be a class name" unless handler.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)

          {
            "path" => path.join(" "), "summary" => summary, "handler" => handler,
            "arguments" => normalize_parameters(entry.fetch("arguments", []), flags: false),
            "flags" => normalize_parameters(entry.fetch("flags", []), flags: true)
          }
        rescue KeyError => e
          raise ArgumentError, "missing #{e.key}"
        end

        def coerce(command, args:, flags:)
          [
            coerce_parameters(command.fetch("arguments"), args.to_h.stringify_keys),
            coerce_parameters(command.fetch("flags"), flags.to_h.stringify_keys)
          ]
        end

        private

        def normalize_parameters(parameters, flags:)
          normalized = Array(parameters).map do |parameter|
            entry = parameter.to_h.stringify_keys
            name = entry.fetch("name").to_s
            raise ArgumentError, "invalid #{flags ? 'flag' : 'argument'} name #{name.inspect}" unless PATH_SEGMENT.match?(name)

            type = entry.fetch("type", "string").to_s
            raise ArgumentError, "bad #{flags ? 'flag' : 'argument'} type #{type.inspect}" unless TYPE_BUILDERS.key?(type)
            values = Array(entry["values"]).map(&:to_s)
            raise ArgumentError, "enum #{name.inspect} requires values" if type == "enum" && values.empty?

            normalized = { "name" => name, "type" => type, "required" => entry.fetch("required", false) == true }
              .merge("values" => values.presence, "default" => entry["default"]).compact
            if normalized.key?("default")
              begin
                TYPE_BUILDERS.fetch(type).call(normalized).coerce(normalized["default"])
              rescue ArgumentError
                raise ArgumentError, "invalid default for parameter #{name.inspect}"
              end
            end
            normalized
          rescue KeyError => e
            raise ArgumentError, "parameter missing #{e.key}"
          end
          duplicates = normalized.group_by { |entry| entry.fetch("name") }.select { |_name, entries| entries.many? }.keys
          raise ArgumentError, "duplicate parameter #{duplicates.first.inspect}" if duplicates.any?

          normalized
        end

        def coerce_parameters(declarations, supplied)
          known = declarations.to_h { |entry| [ entry.fetch("name"), entry ] }
          unknown = supplied.keys - known.keys
          raise ArgumentError, "unknown parameter #{unknown.first.inspect}" if unknown.any?

          declarations.each_with_object({}) do |entry, result|
            name = entry.fetch("name")
            value = supplied.key?(name) ? supplied[name] : entry["default"]
            raise ArgumentError, "missing required parameter #{name.inspect}" if value.nil? && entry.fetch("required")
            next if value.nil?

            result[name] = TYPE_BUILDERS.fetch(entry.fetch("type")).call(entry).coerce(value)
          rescue ArgumentError
            raise ArgumentError, "invalid value for parameter #{name.inspect}"
          end
        end
      end
    end
  end
end
