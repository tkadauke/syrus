module Admin
  class McpToolCardCoverage
    Card = Data.define(:tool_name, :owner_type, :owner_name, :has_collapsed_summary, :path) do
      def strong? = has_collapsed_summary
    end

    Owner = Data.define(:tool_name, :owner_type, :owner_name) do
      def recommendation_target
        owner_type == "plugin" ? "plugin:#{owner_name}" : "core"
      end
    end

    CORE_CARD_GLOB = "app/frontend/routes/chat/tool_cards/*.tsx"
    PLUGIN_CARD_GLOB = "plugins/*/app/frontend/tool_cards/*.tsx"
    TEST_CARD_PATTERN = /\.test\.tsx\z/
    TOOL_NAME_PATTERN = /toolName:\s*["']([^"']+)["']/

    class << self
      def call(usages:, advertised_tools:, single_tool_name: nil, chat_session: nil)
        new(usages: usages, advertised_tools: advertised_tools, single_tool_name: single_tool_name, chat_session: chat_session).as_json
      end
    end

    def initialize(usages:, advertised_tools:, single_tool_name: nil, chat_session: nil)
      @usages = usages
      @advertised_tools = advertised_tools.map(&:to_s).uniq.sort
      @single_tool_name = single_tool_name.to_s.presence
      @chat_session = chat_session
    end

    def as_json
      {
        card_gap_priorities: card_gap_priority_rows,
        high_volume_without_custom_card: missing_card_rows(used_tool_rows),
        high_error_with_weak_or_no_custom_card: weak_or_missing_card_rows(error_tool_rows),
        unused_advertised_tools: unused_advertised_tool_rows
      }
    end

    private

    attr_reader :usages, :advertised_tools, :single_tool_name, :chat_session

    def used_tool_rows
      @used_tool_rows ||= aggregate_rows(usages, order_by: :calls)
    end

    def error_tool_rows
      @error_tool_rows ||= if single_tool_name
        used_tool_rows.select { |row| row[:errors].positive? }
      else
        aggregate_rows(usages, order_by: :error_rate)
      end
    end

    def priority_tool_rows
      @priority_tool_rows ||= aggregate_rows(usages, order_by: :priority, limit_count: Admin::McpToolUsagePayload::DEFAULT_CARD_GAP_LIMIT * 5)
    end

    def aggregate_rows(scope, order_by:, limit_count: Admin::McpToolUsagePayload::DEFAULT_CARD_GAP_LIMIT)
      grouped = scope
        .group(:normalized_tool_name)
        .then { |relation| order_by == :error_rate ? relation.having(Arel.sql("#{error_count_expression} > 0")) : relation }
        .order(aggregate_order(order_by))
        .limit(limit_count)
        .pluck(
          :normalized_tool_name,
          Arel.sql(count_expression),
          Arel.sql(error_count_expression),
          Arel.sql(result_bytes_expression),
          Arel.sql(last_used_at_expression)
        )

      grouped.map do |tool_name, count, errors, result_bytes, last_used_at|
        count = count.to_i
        errors = errors.to_i
        {
          tool_name: tool_name.to_s,
          calls: count,
          errors: errors,
          error_rate: count.positive? ? (errors.to_f / count).round(4) : 0.0,
          result_bytes: result_bytes.to_i,
          last_used_at: formatted_time(last_used_at),
          server_names: server_names_for(tool_name.to_s)
        }
      end
    end

    def aggregate_order(order_by)
      return Arel.sql("#{priority_score_expression} DESC, #{McpToolUsage.quoted_table_name}.normalized_tool_name ASC") if order_by == :priority

      if order_by == :error_rate
        Arel.sql("#{error_rate_expression} DESC, #{error_count_expression} DESC, #{McpToolUsage.quoted_table_name}.normalized_tool_name ASC")
      else
        Arel.sql("#{count_expression} DESC, #{McpToolUsage.quoted_table_name}.normalized_tool_name ASC")
      end
    end

    def count_expression
      "COUNT(*)"
    end

    def error_count_expression
      "SUM(CASE WHEN #{McpToolUsage.quoted_table_name}.error THEN 1 ELSE 0 END)"
    end

    def error_rate_expression
      "(#{error_count_expression} * 1.0 / NULLIF(#{count_expression}, 0))"
    end

    def result_bytes_expression
      "COALESCE(SUM(#{McpToolUsage.quoted_table_name}.result_bytes), 0)"
    end

    def last_used_at_expression
      "MAX(COALESCE(#{McpToolUsage.quoted_table_name}.completed_at, #{McpToolUsage.quoted_table_name}.started_at, #{McpToolUsage.quoted_table_name}.created_at))"
    end

    def priority_score_expression
      "(#{count_expression} * 1.0 + #{error_count_expression} * 5.0 + #{result_bytes_expression} / 16384.0)"
    end

    def card_gap_priority_rows
      rows = priority_tool_rows.filter_map do |row|
        card = cards[row[:tool_name]]
        next if card&.strong?

        row_payload(row).merge(
          card_status: card ? "weak" : "missing",
          priority_score: priority_score(row),
          priority_label: priority_label(row)
        )
      end

      unused_advertised_tool_rows.each do |row|
        next if row[:card_status] == "registered"

        rows << row.merge(
          calls: 0,
          errors: 0,
          error_rate: 0.0,
          result_bytes: 0,
          last_used_at: nil,
          server_names: [],
          priority_score: 0.0,
          priority_label: "defer"
        )
      end

      rows.sort_by { |row| [ -row[:priority_score].to_f, row[:tool_name].to_s ] }
          .first(Admin::McpToolUsagePayload::DEFAULT_CARD_GAP_LIMIT)
    end

    def priority_score(row)
      (row[:calls].to_i * 1.0 + row[:errors].to_i * 5.0 + row[:result_bytes].to_i / 16.kilobytes.to_f).round(2)
    end

    def priority_label(row)
      return "build_next" if row[:calls].to_i >= 10 || row[:result_bytes].to_i >= 64.kilobytes
      return "investigate_errors" if row[:errors].to_i.positive?

      "defer"
    end

    def missing_card_rows(rows)
      rows.filter_map do |row|
        next if cards.key?(row[:tool_name])

        row_payload(row).merge(card_status: "missing")
      end
    end

    def weak_or_missing_card_rows(rows)
      rows.filter_map do |row|
        card = cards[row[:tool_name]]
        next if card&.strong?

        row_payload(row).merge(card_status: card ? "weak" : "missing")
      end
    end

    def unused_advertised_tool_rows
      used = usages.distinct.pluck(:normalized_tool_name).map(&:to_s).to_set
      (advertised_tools - used.to_a).map do |tool_name|
        owner = owners[tool_name] || Owner.new(tool_name: tool_name, owner_type: "core", owner_name: "core")
        card = cards[tool_name]
        {
          tool_name: tool_name,
          owner_type: owner.owner_type,
          owner_name: owner.owner_name,
          recommendation_target: owner.recommendation_target,
          card_status: card ? (card.strong? ? "registered" : "weak") : "missing"
        }
      end
    end

    def row_payload(row)
      owner = owners[row[:tool_name]] || Owner.new(tool_name: row[:tool_name], owner_type: "core", owner_name: "core")
      {
        tool_name: row[:tool_name],
        calls: row[:calls],
        errors: row[:errors],
        error_rate: row[:error_rate],
        result_bytes: row[:result_bytes],
        last_used_at: row[:last_used_at],
        server_names: row[:server_names] || [],
        owner_type: owner.owner_type,
        owner_name: owner.owner_name,
        recommendation_target: owner.recommendation_target
      }
    end

    def owners
      @owners ||= core_tool_owners.merge(plugin_tool_owners)
    end

    def core_tool_owners
      McpToolRegistry.summaries(surface: :chat).each_with_object({}) do |entry, index|
        tool_name = entry[:tool_name].to_s
        index[tool_name] = Owner.new(tool_name: tool_name, owner_type: "core", owner_name: "core")
      end
    end

    def plugin_tool_owners
      enabled_tool_sets = Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set).to_set
      Syrus::PluginRegistry.all_plugins.each_with_object({}) do |manifest, index|
        Array(manifest.provides[:chat_mcp_tool_set]).select { |tool_set| enabled_tool_sets.include?(tool_set) }.each do |tool_set|
          plugin_tool_names(tool_set).each do |tool_name|
            index[tool_name] = Owner.new(tool_name: tool_name, owner_type: "plugin", owner_name: manifest.name)
          end
        end
      end
    end

    def plugin_tool_names(tool_set)
      McpToolUsageRecorder::CHAT_TOOL_TIERS.flat_map do |tier|
        next [] unless plugin_chat_tool_set_available?(tool_set, tier: tier)

        tool_definitions(tool_set, tier: tier)
      end.filter_map { |definition| definition[:name].presence&.to_s }.uniq
    end

    def plugin_chat_tool_set_available?(tool_set, tier:)
      tool_set.available_for?(chat_session, tier: tier)
    rescue StandardError, NoMethodError
      false
    end

    def tool_definitions(tool_set, tier:)
      method = tool_set.method(:tool_definitions)
      keywords = method.parameters.select { |type, _name| type == :key || type == :keyreq }.map(&:last)
      if keywords.include?(:tier)
        args = { tier: tier }
        args[:chat_session] = chat_session if keywords.include?(:chat_session)
        return Array(tool_set.tool_definitions(**args))
      end
      return Array(tool_set.tool_definitions(context: nil)) if keywords.include?(:context)

      Array(tool_set.tool_definitions)
    rescue StandardError, NotImplementedError
      []
    end

    def cards
      @cards ||= card_paths.each_with_object({}) do |path, index|
        card = card_from_path(path)
        index[card.tool_name] = card if card
      end
    end

    def card_paths
      (Dir.glob(Rails.root.join(CORE_CARD_GLOB).to_s) + Dir.glob(Rails.root.join(PLUGIN_CARD_GLOB).to_s))
        .reject { |path| path.match?(TEST_CARD_PATTERN) }
    end

    def card_from_path(path)
      source = File.read(path)
      tool_name = source[TOOL_NAME_PATTERN, 1]
      return if tool_name.blank?

      owner_type, owner_name = card_owner(path)
      Card.new(
        tool_name: tool_name,
        owner_type: owner_type,
        owner_name: owner_name,
        has_collapsed_summary: source.include?("collapsedSummary"),
        path: relative_path(path)
      )
    rescue Errno::ENOENT
      nil
    end

    def card_owner(path)
      relative = relative_path(path)
      match = relative.match(%r{\Aplugins/([^/]+)/})
      return [ "plugin", match[1] ] if match

      [ "core", "core" ]
    end

    def relative_path(path)
      Pathname.new(path).relative_path_from(Rails.root).to_s
    rescue ArgumentError
      path.to_s
    end

    def server_names_for(tool_name)
      server_names_by_tool.fetch(tool_name, [])
    end

    def server_names_by_tool
      @server_names_by_tool ||= usages
        .where.not(server_name: nil)
        .group(:normalized_tool_name, :server_name)
        .pluck(:normalized_tool_name, :server_name, Arel.sql(count_expression))
        .group_by { |tool_name, _server_name, _count| tool_name.to_s }
        .transform_values do |rows|
          rows.sort_by { |_tool_name, server_name, count| [ -count.to_i, server_name.to_s ] }
              .first(3)
              .map { |_tool_name, server_name, _count| server_name.to_s }
        end
    end

    def formatted_time(value)
      return if value.blank?
      return value.iso8601 if value.respond_to?(:iso8601)

      Time.zone.parse(value.to_s)&.iso8601
    rescue ArgumentError, TypeError
      nil
    end
  end
end
