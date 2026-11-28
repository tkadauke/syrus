# frozen_string_literal: true

module SpendingInsights
  module Cli
    class Spending < Syrus::Host::CliCommandHandler
      GROUPS = {
        "repo" => [ "repository", :repositories ],
        "user" => [ "user", :users ],
        "epic" => [ "epic", :epics ]
      }.freeze
      GROUP_ALIASES = {
        "repository" => "repo", "repositories" => "repo",
        "users" => "user", "epics" => "epic",
        "trigger-kind" => "trigger_kind", "trigger_kinds" => "trigger_kind"
      }.freeze

      def call(args:, flags:, user:)
        params = {}
        params[:start_date] = iso_date!("--since", flags["since"]) if flags["since"].present?
        params[:end_date] = iso_date!("--until", flags["until"]) if flags["until"].present?
        payload = SpendingInsights::Payload.new(user: user, params: params).as_json
        return self.class.text(JSON.generate(payload)) if flags["json"]

        self.class.text(render(payload, normalize_group(flags.fetch("group-by", "repo"))))
      end

      private

      def iso_date!(flag, value)
        Date.iso8601(value.to_s).iso8601
      rescue Date::Error
        raise ArgumentError, %(#{flag}: invalid date #{value.inspect}, expected YYYY-MM-DD)
      end

      def normalize_group(value)
        group = value.to_s.strip.downcase
        group = GROUP_ALIASES.fetch(group, group)
        return group if GROUPS.key?(group) || group == "trigger_kind"

        raise ArgumentError, %(unknown --group-by #{value.inspect}; must be one of repo, user, epic, trigger_kind)
      end

      def render(payload, group)
        scope = payload.fetch(:scope)
        totals = payload.fetch(:totals)
        label = scope.fetch(:label)
        label = "#{label} (instance-wide)" if scope.fetch(:admin)
        lines = [ "Scope: #{label}", "Window: #{payload.dig(:filters, :start_date)} to #{payload.dig(:filters, :end_date)}", "", "Totals" ]
        lines << format("  This week:                  $%.2f", totals.fetch(:week_usd))
        lines << format("  This month:                 $%.2f", totals.fetch(:month_usd))
        lines << format("  Lifetime:                   $%.2f (workflows: $%.2f, chats: $%.2f)", totals.fetch(:lifetime_usd), totals.fetch(:workflow_lifetime_usd), totals.fetch(:chat_lifetime_usd))
        lines << format("  Avg cost / job (30d):       $%.2f", totals.fetch(:average_job_30d_usd))
        lines << format("  Avg cost / merged PR (30d): $%.2f", totals.fetch(:average_merged_pr_30d_usd))
        lines << ""
        group == "trigger_kind" ? render_trigger_kinds(lines, payload) : render_group(lines, payload, group)
        lines.join("\n")
      end

      def render_group(lines, payload, group)
        label, key = GROUPS.fetch(group)
        rows = payload.dig(:breakdowns, key)
        lines << "By #{label}"
        return lines << "  No spend in this window." if rows.empty?

        table = [ [ "  LABEL", "JOBS", "TOTAL", "AVG/JOB" ] ]
        rows.each { |row| table << [ "  #{row.fetch(:label)}", row.fetch(:jobs_count).to_s, format("$%.2f", row.fetch(:total_usd)), format("$%.2f", row.fetch(:average_job_usd)) ] }
        lines << format_table(table)
      end

      def render_trigger_kinds(lines, payload)
        rows = payload.dig(:breakdowns, :trigger_kinds)
        lines << "By trigger kind"
        return lines << "  No spend in this window." if rows.empty?

        table = [ [ "  TRIGGER KIND", "JOBS", "RUNS", "TOTAL", "AVG/RUN" ] ]
        rows.each { |row| table << [ "  #{row.fetch(:trigger_kind)}", row.fetch(:jobs_count).to_s, row.fetch(:runs_count).to_s, format("$%.2f", row.fetch(:total_usd)), format("$%.2f", row.fetch(:average_usd)) ] }
        lines << format_table(table)
      end

      def format_table(rows)
        widths = rows.transpose.map { |column| column.map(&:length).max }
        rows.map { |row| row.each_with_index.map { |cell, index| index == row.length - 1 ? cell : cell.ljust(widths.fetch(index) + 2) }.join.rstrip }.join("\n")
      end
    end
  end
end
