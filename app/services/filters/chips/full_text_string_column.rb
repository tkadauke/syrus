module Filters
  module Chips
    # Search-style text chip used by FilterBar's typed-query suggestions.
    # The `matches` operator is intentionally distinct from StringColumn's
    # `contains` label: it represents a reusable search primitive. Until a
    # subject wires a database-specific full-text index, this base provides a
    # documented cross-DB LIKE fallback so dev/test and SQLite remain supported.
    class FullTextStringColumn < StringColumn
      operators :matches, *StringColumn.operators
      full_text_suggestions true

      def apply
        return like(self.class.column, "%#{escape_like(value)}%") if op == :matches

        super
      end
    end
  end
end
