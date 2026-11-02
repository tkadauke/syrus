module Permissions
  module ImmutableValue
    module_function

    def deep_freeze(value)
      case value
      when Hash
        value.to_h { |key, item| [ deep_freeze(key), deep_freeze(item) ] }.freeze
      when Array
        value.map { |item| deep_freeze(item) }.freeze
      when String
        value.dup.freeze
      else
        value.freeze
      end
    end
  end
end
