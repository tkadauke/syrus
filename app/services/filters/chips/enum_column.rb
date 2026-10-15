module Filters
  module Chips
    # Base for chips that delegate to a single enum-like column on
    # Job. Subclasses declare:
    #
    #   filter_name "priority"
    #   column :priority
    #
    # Operator vocabulary is the same for every enum: is / is_not /
    # is_one_of / is_none_of / is_set / is_unset.
    class EnumColumn < Base
      bucket :enum
      operators :is, :is_not, :is_one_of, :is_none_of, :is_set, :is_unset

      class << self
        def column(name = nil)
          @column = name.to_sym if name
          @column or raise NotImplementedError, "#{self.name} must declare `column :name`"
        end
      end

      def apply
        col = self.class.column
        case op
        when :is        then scope.where(col => value)
        when :is_not    then exclude_matches(scope.where(col => value))
        when :is_one_of then scope.where(col => Array(value))
        when :is_none_of then exclude_matches(scope.where(col => Array(value)))
        when :is_set    then scope.where.not(col => nil)
        when :is_unset  then scope.where(col => nil)
        else unsupported_op!
        end
      end
    end
  end
end
