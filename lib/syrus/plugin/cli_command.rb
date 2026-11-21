# frozen_string_literal: true

module Syrus
  module Plugin
    class CliCommand
      TYPES = %w[string boolean integer enum repeatable_string].freeze
      ValidationError = Class.new(StandardError)
      TYPE_COERCERS = {
        "string" => ->(value, _parameter) { value.to_s },
        "repeatable_string" => lambda { |value, parameter|
          raise ValidationError, "#{parameter[:name]} must be a list of strings" unless value.is_a?(Array)
          value.map(&:to_s)
        },
        "integer" => ->(value, _parameter) { Integer(value.to_s, 10) },
        "boolean" => lambda { |value, parameter|
          return value if value == true || value == false
          return true if value.to_s == "true"
          return false if value.to_s == "false"
          raise ValidationError, "#{parameter[:name]} must be a boolean"
        },
        "enum" => lambda { |value, parameter|
          string = value.to_s
          raise ValidationError, "#{parameter[:name]} must be one of: #{parameter[:values].join(', ')}" unless parameter[:values].include?(string)
          string
        }
      }.freeze

      attr_reader :plugin, :path, :summary, :arguments, :flags, :handler

      def self.normalize_all(plugin:, declarations:)
        commands = Array(declarations).map { |entry| new(plugin: plugin, declaration: entry) }
        duplicates = commands.group_by(&:path).select { |_path, entries| entries.many? }.keys
        raise ValidationError, "duplicate CLI command path: #{duplicates.first.join(' ')}" if duplicates.any?

        commands.freeze
      end

      # Commands of different plugins collide when one path equals or is a
      # prefix of the other: the CLI mounts paths bare, so either would decide
      # by catalog order which of them is reachable. Returns command => the
      # other plugins' commands it collides with. A plugin's own nested
      # commands (`docs` and `docs list`) never collide.
      def self.collisions(commands)
        commands.each_with_object({}) do |command, found|
          others = commands.select do |other|
            other.plugin != command.plugin && (other.path.first(command.path.length) == command.path || command.path.first(other.path.length) == other.path)
          end
          found[command] = others if others.any?
        end
      end

      def initialize(plugin:, declaration:)
        entry = declaration.to_h.deep_symbolize_keys
        @plugin = plugin.to_s
        @path = Array(entry[:path]).presence || entry[:path].to_s.split
        @summary = entry[:summary].to_s
        @handler = entry[:handler].to_s
        @arguments = normalize_parameters(entry[:arguments], flags: false)
        @flags = normalize_parameters(entry[:flags], flags: true)
        validate!
      rescue NoMethodError, TypeError
        raise ValidationError, "CLI command declarations must be objects"
      end

      def key = path.join(" ")

      def catalog_payload
        { plugin: plugin, path: path, summary: summary, arguments: arguments, flags: flags }
      end

      def validate_inputs(args:, flags:)
        raise ValidationError, "args must be a list" unless args.nil? || args.is_a?(Array)
        raise ValidationError, "flags must be an object" unless flags.nil? || flags.is_a?(Hash)

        raw_args = args || []
        raw_flags = (flags || {}).stringify_keys
        unknown_flags = raw_flags.keys - self.flags.map { |flag| flag.fetch(:name) }
        raise ValidationError, "unknown flag: #{unknown_flags.first}" if unknown_flags.any?

        parsed_args = arguments.each_with_index.map do |argument, index|
          value = raw_args[index]
          value = argument[:default] if value.nil? && argument.key?(:default)
          validate_value!(argument, value)
        end
        raise ValidationError, "too many arguments" if raw_args.length > arguments.length

        parsed_flags = self.flags.each_with_object({}) do |flag, parsed|
          value = raw_flags.key?(flag[:name]) ? raw_flags[flag[:name]] : flag[:default]
          parsed[flag[:name]] = validate_value!(flag, value) unless value.nil?
        end
        [ parsed_args, parsed_flags ]
      end

      def handler_class
        handler.constantize.tap do |klass|
          raise ValidationError, "handler #{handler} must inherit Syrus::Plugin::CliCommandHandler" unless klass <= CliCommandHandler
        end
      rescue NameError
        raise ValidationError, "handler #{handler} is unavailable"
      end

      private

      def normalize_parameters(entries, flags:)
        Array(entries).map do |parameter|
          normalized = parameter.to_h.deep_symbolize_keys
          normalized[:name] = normalized[:name].to_s
          normalized[:type] = normalized.fetch(:type, :string).to_s
          normalized[:required] = normalized[:required] == true
          normalized[:values] = Array(normalized[:values]).map(&:to_s) if normalized[:type] == "enum"
          normalized.compact
        end.tap do |parameters|
          names = parameters.map { |parameter| parameter[:name] }
          raise ValidationError, "duplicate #{flags ? 'flag' : 'argument'} name" if names.uniq.length != names.length
        end
      end

      def validate!
        raise ValidationError, "CLI command path is required" if path.blank? || path.any? { |part| part.to_s !~ /\A[a-z0-9][a-z0-9_-]*\z/ }
        raise ValidationError, "CLI command summary is required" if summary.blank? || summary.lines.length > 1
        raise ValidationError, "CLI command handler is required" if handler.blank?

        (arguments + flags).each do |parameter|
          raise ValidationError, "CLI command parameter name is required" if parameter[:name].blank?
          raise ValidationError, "unsupported CLI command type: #{parameter[:type]}" unless TYPES.include?(parameter[:type])
          raise ValidationError, "enum #{parameter[:name]} requires values" if parameter[:type] == "enum" && parameter[:values].blank?
        end
      end

      def validate_value!(parameter, value)
        if value.nil?
          raise ValidationError, "#{parameter[:name]} is required" if parameter[:required]
          return nil
        end

        TYPE_COERCERS.fetch(parameter[:type]).call(value, parameter)
      rescue ArgumentError, TypeError
        raise ValidationError, "#{parameter[:name]} must be an integer"
      end
    end
  end
end
