# frozen_string_literal: true

module Syrus
  module Plugin
    class CliCommandHandler
      Result = Data.define(:kind, :payload) do
        def as_json(*) = { kind: kind }.merge(payload)
      end

      def self.table(columns:, rows:) = Result.new(kind: "table", payload: { columns: columns, rows: rows })
      def self.text(text) = Result.new(kind: "text", payload: { text: text.to_s })
      def self.raw_text(text) = Result.new(kind: "raw_text", payload: { text: text.to_s })
      def self.json(value) = Result.new(kind: "json", payload: { value: value })

      def call(args:, flags:, user:)
        raise NotImplementedError, "#{self.class.name} must implement #call(args:, flags:, user:)"
      end
    end
  end
end
