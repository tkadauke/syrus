module Filters
  module Chips
    # Base for chips that filter on a foreign-key column. Same
    # operator vocabulary as EnumColumn; separate from EnumColumn so
    # the UI editor can show an id-picker (with autocomplete) instead
    # of a static dropdown.
    class FkColumn < Base
      bucket :fk
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
