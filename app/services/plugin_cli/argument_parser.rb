module PluginCli
  class ArgumentParser
    module Coercers
      class StringValue
        def self.call(_definition, value) = value.to_s
      end

      class BooleanValue
        def self.call(_definition, value)
          return value if value == true || value == false
          return true if value == "true"
          return false if value == "false"

          raise ArgumentError
        end
      end

      class IntegerValue
        def self.call(_definition, value) = Integer(value, exception: true)
      end

      class EnumValue
        def self.call(definition, value)
          value = value.to_s
          raise ArgumentError unless definition.fetch("values").map(&:to_s).include?(value)
          value
        end
      end

      class RepeatableStringValue
        def self.call(_definition, value) = Array(value).map(&:to_s)
      end

      BY_TYPE = {
        "string" => StringValue,
        "boolean" => BooleanValue,
        "integer" => IntegerValue,
        "enum" => EnumValue,
        "repeatable_string" => RepeatableStringValue
      }.freeze
    end

    def initialize(command, args:, flags:)
      @command = command
      @args = args
      @flags = flags
    end

    def parse
      @args = parameter_hash(@args).stringify_keys
      @flags = parameter_hash(@flags).stringify_keys
      unknown = @args.keys - argument_definitions.map { |item| item.fetch("name") }
      unknown += @flags.keys - flag_definitions.map { |item| item.fetch("name") }
      invalid!("unknown values: #{unknown.join(', ')}") if unknown.any?

      [ parse_values(argument_definitions, @args), parse_values(flag_definitions, @flags) ]
    rescue NoMethodError, TypeError
      invalid!("args and flags must be objects")
    end

    private

    def parameter_hash(value)
      value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value.to_h
    end

    def argument_definitions = @command.fetch("arguments")
    def flag_definitions = @command.fetch("flags")

    def parse_values(definitions, supplied)
      definitions.each_with_object({}) do |definition, parsed|
        name = definition.fetch("name")
        value = supplied.key?(name) ? supplied[name] : definition["default"]
        invalid!("#{name} is required") if value.nil? && definition["required"]
        parsed[name] = coerce(definition, value) unless value.nil?
      end
    end

    def coerce(definition, value)
      type = definition.fetch("type")
      Coercers::BY_TYPE.fetch(type).call(definition, value)
    rescue KeyError
      invalid!("#{definition.fetch('name')} has unsupported type")
    rescue ArgumentError, TypeError
      invalid!("#{definition.fetch('name')} must be a #{type}")
    end

    def invalid!(message)
      raise Syrus::Plugin::CliCommand::InvalidArguments, message
    end
  end
end
