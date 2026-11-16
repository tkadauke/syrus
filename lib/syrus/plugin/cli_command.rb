module Syrus
  module Plugin
    module CliCommand
      def call(args:, flags:, user:)
        raise NotImplementedError, "#{self.class.name} must implement #call(args:, flags:, user:)"
      end

      class Result
        attr_reader :kind

        def initialize(kind) = @kind = kind
      end

      class Table < Result
        attr_reader :columns, :rows
        def initialize(columns:, rows:) = (super("table"); @columns = columns; @rows = rows)
        def as_json(*) = { kind: kind, columns: columns, rows: rows }
      end

      class Text < Result
        attr_reader :text
        def initialize(text:) = (super("text"); @text = text)
        def as_json(*) = { kind: kind, text: text }
      end

      class Json < Result
        attr_reader :value
        def initialize(value:) = (super("json"); @value = value)
        def as_json(*) = { kind: kind, value: value }
      end
    end
  end
end
