module Filters
  module Chips
    class BooleanColumn < Base
      bucket :boolean
      operators :is_true, :is_false

      class << self
        def true_scope(name = nil)
          @true_scope = name.to_sym if name
          @true_scope or raise NotImplementedError, "#{self.name} must declare `true_scope :name`"
        end

        def false_scope(name = nil)
          @false_scope = name.to_sym if name
          @false_scope or raise NotImplementedError, "#{self.name} must declare `false_scope :name`"
        end
      end

      def apply
        case op
        when :is_true  then scope.public_send(self.class.true_scope)
        when :is_false then scope.public_send(self.class.false_scope)
        else unsupported_op!
        end
      end
    end
  end
end
