module Filters
  module Chips
    # Base class for chip implementations. Concrete chips declare their
    # bucket (drives the UI editor type) and their supported operator
    # set via the `bucket` and `operators` DSL, and override `#apply`.
    #
    #   class State < Base
    #     filter_name "state"
    #     bucket :enum
    #     operators :is, :is_not, :is_one_of, :is_none_of
    #
    #     def apply
    #       case op
    #       when :is then scope.where(state: value)
    #       ...
    #       end
    #     end
    #   end
    class Base
      class << self
        # Ruby class instance variables don't inherit. Each getter
        # below walks the ancestor chain so a subclass that declares
        # only `column :foo` still inherits its parent's `bucket`,
        # `operators`, and `values`. Without this, EnumColumn's
        # `bucket :enum` would be visible only when querying
        # EnumColumn itself — every subclass would report a blank
        # bucket and the chip-bar UI would fall back to free-text.
        def filter_name(name = nil)
          @filter_name = name.to_s if name
          @filter_name || (superclass.respond_to?(:filter_name) ? superclass.filter_name : nil)
        end

        def label(text = nil)
          @label = text.to_s if text
          return @label if defined?(@label) && @label
          inherited = superclass.respond_to?(:label) ? superclass.label : nil
          inherited || filter_name.to_s.humanize
        end

        def bucket(name = nil)
          @bucket = name.to_sym if name
          return @bucket if defined?(@bucket) && @bucket
          superclass.respond_to?(:bucket) ? superclass.bucket : nil
        end

        def operators(*ops)
          @operators = ops.map(&:to_sym).freeze if ops.any?
          return @operators if defined?(@operators) && @operators&.any?
          superclass.respond_to?(:operators) ? superclass.operators : [].freeze
        end

        # Static value-set for enum-style chips. Returns an empty
        # array for buckets that take free input (strings, numbers,
        # dates) — the editor falls back to a text/number/date
        # widget in that case.
        #
        # Entries may be plain strings (auto-humanized into labels
        # by Filters::Schema.humanize_values) OR `{"value" => ...,
        # "label" => ...}` hashes for cases where the default
        # humanization would mislead — e.g. the Jobs::State chip's
        # "open" composite value needs the label "Any open" to
        # distinguish it from the AASM :open state.
        def values(*list)
          @values = list.flatten.map { |v| v.is_a?(Hash) ? v.transform_keys(&:to_s) : v.to_s }.freeze if list.any?
          return @values if defined?(@values) && @values&.any?
          superclass.respond_to?(:values) ? superclass.values : [].freeze
        end

        def typeahead(enabled = nil)
          @typeahead = enabled unless enabled.nil?
          return @typeahead if defined?(@typeahead)
          superclass.respond_to?(:typeahead) ? superclass.typeahead : false
        end
      end

      def initialize(scope:, op:, value:, user: nil)
        @scope = scope
        @op = op.to_sym
        @value = value
        @user = user
      end

      def apply
        raise NotImplementedError, "#{self.class} must implement #apply"
      end

      private

      attr_reader :scope, :op, :value, :user

      def unsupported_op!
        raise ArgumentError, "#{self.class.filter_name}: unsupported operator #{op.inspect}"
      end
    end
  end
end
