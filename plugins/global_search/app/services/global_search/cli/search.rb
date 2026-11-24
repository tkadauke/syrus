# frozen_string_literal: true

module GlobalSearch
  module Cli
    class Search < Syrus::Host::CliCommandHandler
      TYPES = %w[job epic chat repository].freeze

      def call(args:, flags:, user:)
        query = args.fetch(0).strip
        raise ArgumentError, "query must be at least 2 characters." if query.length < 2

        types = parse_types(flags["type"])
        limit = flags.fetch("limit", 0).to_i
        limit = Api::V1::App::SearchController::DEFAULT_LIMIT if limit <= 0
        limit = limit.clamp(1, Api::V1::App::SearchController::MAX_LIMIT)
        payload = search(query:, types:, limit:, user:)
        return self.class.text(JSON.generate(payload)) if flags["json"]

        self.class.text(render(payload.fetch(:results)))
      end

      private

      def parse_types(value)
        return Api::V1::App::SearchController.types if value.blank?

        types = value.split(",").map { |type| type.strip.downcase }.reject(&:blank?)
        unknown = types - TYPES
        raise ArgumentError, %(unknown --type #{unknown.first.inspect}; must be one of job, epic, chat, repository) if unknown.any?
        raise ArgumentError, "--type must not be blank" if types.empty?

        types
      end

      def search(query:, types:, limit:, user:)
        controller = Api::V1::App::SearchController.new
        controller.request = ActionDispatch::Request.new(Rack::MockRequest.env_for("/"))
        controller.params = ActionController::Parameters.new
        rows = types.flat_map do |type|
          source = Api::V1::App::SearchController.source_for(type, controller: controller)
          Array(source.search_rows(query: query, user: user, limit: limit)).each_with_index.map do |row, index|
            row.merge(type: type, type_order: types.index(type), priority: row.fetch(:priority, 0), ordinal: index)
          end
        end
        rows = controller.send(:grouped_chat_rows, rows)
        rows = controller.send(:normalized_rows, rows)
        rows.sort_by! { |row| [ row.fetch(:priority), row.fetch(:rank), row.fetch(:type_order), row.fetch(:ordinal) ] }
        rows = rows.first(limit)
        controller.instance_variable_set(:@search_result_rows, rows)
        { results: rows.filter_map { |row| Api::V1::App::SearchController.source_for(row.fetch(:type), controller: controller)&.result_json(row: row, user: user) }, filter: {} }
      end

      def render(results)
        return "No results." if results.empty?

        results.group_by { |result| result.fetch(:type) }.map do |type, rows|
          table = [ [ "  ID", "STATE", "TITLE", "REPO", "MATCH" ] ]
          rows.each do |row|
            identifier = row[:slug].presence || "##{row.fetch(:id)}"
            table << [ "  #{identifier}", value_or_dash(row[:state]), truncate(row.fetch(:title), 40), value_or_dash(row[:repository_slug]), truncate(row.fetch(:snippet).gsub(%r{</?mark>}, ""), 60) ]
          end
          [ "#{type.upcase} (#{rows.length})", format_table(table) ].join("\n")
        end.join("\n\n")
      end

      def format_table(rows)
        widths = rows.transpose.map { |column| column.map(&:length).max }
        rows.map { |row| row.each_with_index.map { |cell, index| index == row.length - 1 ? cell : cell.ljust(widths.fetch(index) + 2) }.join.rstrip }.join("\n")
      end

      def value_or_dash(value) = value.to_s.strip.presence || "-"

      def truncate(value, width)
        text = value.to_s.strip
        return value_or_dash(text) if text.length <= width

        "#{text.each_char.take(width - 1).join}…"
      end
    end
  end
end
