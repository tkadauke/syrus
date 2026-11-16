# frozen_string_literal: true

module Syrus
  module Plugin
    class CliCommandHandler
      Result = Data.define(:kind, :payload) do
        def self.table(columns:, rows:) = new(kind: "table", payload: { columns: Array(columns), rows: Array(rows) })
        def self.text(text) = new(kind: "text", payload: { text: text.to_s })
        def self.json(value) = new(kind: "json", payload: { value: value })

        def as_json(*) = { kind: kind }.merge(payload)
      end

      def call(args:, flags:, user:)
        raise NotImplementedError
      end
    end
  end
end
