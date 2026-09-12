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
      def call(usages:, advertised_tools:, single_tool_name: nil)
        new(usages: usages, advertised_tools: advertised_tools, single_tool_name: single_tool_name).as_json
      end
    end

    def initialize(usages:, advertised_tools:, single_tool_name: nil)
      @usages = usages
      @advertised_tools = advertised_tools.map(&:to_s).uniq.sort
      @single_tool_name = single_tool_name.to_s.presence
    end

    def as_json
      {
        high_volume_without_custom_card: missing_card_rows(used_tool_rows),
        high_error_with_weak_or_no_custom_card: weak_or_missing_card_rows(error_tool_rows),
        unused_advertised_tools: unused_advertised_tool_rows
      }
    end

    private

    attr_reader :usages, :advertised_tools, :single_tool_name

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

    def aggregate_rows(scope, order_by:)
      grouped = scope
        .group(:normalized_tool_name)
        .then { |relation| order_by == :error_rate ? relation.having(Arel.sql("#{error_count_expression} > 0")) : relation }
        .order(aggregate_order(order_by))
        .limit(Admin::McpToolUsagePayload::DEFAULT_CARD_GAP_LIMIT)
        .pluck(:normalized_tool_name, Arel.sql(count_expression), Arel.sql(error_count_expression))

      grouped.map do |tool_name, count, errors|
        count = count.to_i
        errors = errors.to_i
        {
          tool_name: tool_name.to_s,
          calls: count,
          errors: errors,
          error_rate: count.positive? ? (errors.to_f / count).round(4) : 0.0
        }
      end
    end

    def aggregate_order(order_by)
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
      Syrus::PluginRegistry.all_plugins.each_with_object({}) do |manifest, index|
        plugin_tool_names(manifest).each do |tool_name|
          index[tool_name] = Owner.new(tool_name: tool_name, owner_type: "plugin", owner_name: manifest.name)
        end
      end
    end

    def plugin_tool_names(manifest)
      (Array(manifest.provides[:chat_mcp_tool_set]) + Array(manifest.provides[:mcp_tool_set]))
        .flat_map { |tool_set| tool_definitions(tool_set) }
        .filter_map { |definition| definition[:name].presence&.to_s }
        .uniq
    end

    def tool_definitions(tool_set)
      method = tool_set.method(:tool_definitions)
      keywords = method.parameters.select { |type, _name| type == :key || type == :keyreq }.map(&:last)
      return Array(tool_set.tool_definitions(tier: nil)) if keywords.include?(:tier)
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
  end
end
