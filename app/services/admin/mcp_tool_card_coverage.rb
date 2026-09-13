module Admin
  class McpToolCardCoverage
    Card = Data.define(:tool_name, :owner_type, :owner_name, :has_collapsed_summary, :path) do
      def strong? = has_collapsed_summary
    end

    CardDecision = Data.define(:tool_name, :status, :reason)

    Owner = Data.define(:tool_name, :owner_type, :owner_name) do
      def recommendation_target
        owner_type == "plugin" ? "plugin:#{owner_name}" : "core"
      end
    end

    CORE_CARD_GLOB = "app/frontend/routes/chat/tool_cards/*.tsx"
    PLUGIN_CARD_GLOB = "plugins/*/app/frontend/tool_cards/*.tsx"
    TEST_CARD_PATTERN = /\.test\.tsx\z/
    TOOL_NAME_PATTERN = /toolName:\s*["']([^"']+)["']/
    SHARED_CARD_PATTERNS = [
      /maintenanceToolCard\(\s*["']([^"']+)["']\s*\)/,
      /runtimeToolCardRenderer\(\s*["']([^"']+)["']\s*\)/
    ].freeze
    EXPLICIT_CARD_DECISIONS = {
      "admin_maintenance_tasks" => [ "generic", "Maintenance task payloads vary by action; keep the bounded raw details fallback until this tool's result shapes settle." ],
      "complete_implement_step" => [ "hidden", "Coding handoff result is surfaced through the pending-action confirmation card rather than a standalone tool-result card." ],
      "force_fail_job" => [ "generic", "Admin-only emergency state override; the pending-action card covers confirmations and raw details are intentional for audit evidence." ],
      "force_rebase" => [ "generic", "Admin-only repair command with compact JSON result; raw details are currently the clearest audit trail." ],
      "force_state_transition" => [ "generic", "Admin-only repair command with intentionally direct transition evidence." ],
      "get_spending" => [ "deferred", "Plugin tool is deferred-tier and its larger reporting surface lives on the Spending Insights plugin page." ],
      "get_walkthrough_analysis" => [ "deferred", "Video walkthrough analysis is deferred-tier and mostly returns large text/image analysis better handled by raw details for now." ],
      "analyze_walkthrough_segment" => [ "deferred", "Video walkthrough segment analysis is deferred-tier and intentionally remains generic while the plugin surface evolves." ],
      "manual_agentic_run" => [ "generic", "Admin-only launch tool whose durable outcome is the spawned workflow/run rather than the immediate MCP result." ],
      "read_walkthrough_frame" => [ "deferred", "Video walkthrough frame reads are deferred-tier and currently rely on the media/result preview fallback." ],
      "refresh_pr_checks" => [ "generic", "Admin-only GitHub recheck command with small status payloads." ],
      "reset_workspace" => [ "generic", "Coding Mode reset responses intentionally show raw status/ref details so the destructive path stays auditable." ],
      "restack_epic" => [ "generic", "Admin-only stack repair launcher; the resulting workflow state is the primary UI." ],
      "set_bookmark" => [ "hidden", "Bookmark changes are reflected in chat chrome state, so a standalone result card would duplicate the surrounding UI." ],
      "submit_chat_feedback" => [ "hidden", "Feedback submission is represented by the resulting pending-action/workflow cards." ],
      "submit_coding_changes" => [ "hidden", "Coding changes create an operator confirmation card; the raw tool result is not the user-facing handoff surface." ]
    }.transform_values { |status, reason| { status: status, reason: reason } }.freeze

    class << self
      def call(usages:, advertised_tools:, single_tool_name: nil, chat_session: nil)
        new(usages: usages, advertised_tools: advertised_tools, single_tool_name: single_tool_name, chat_session: chat_session).as_json
      end

      def explicit_card_decisions
        EXPLICIT_CARD_DECISIONS.transform_values { |decision| decision.slice(:status, :reason) }
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
        ranked_gaps: ranked_gap_rows,
        high_volume_without_custom_card: missing_card_rows(used_tool_rows),
        high_error_with_weak_or_no_custom_card: weak_or_missing_card_rows(error_tool_rows),
        unused_advertised_tools: unused_advertised_tool_rows,
        unclassified_advertised_tools: unclassified_advertised_tool_rows
      }
    end

    private

    attr_reader :usages, :advertised_tools, :single_tool_name, :chat_session

    def used_tool_rows
      @used_tool_rows ||= used_rank_rows.map do |row|
        row.slice(:tool_name, :calls, :errors, :error_rate)
      end
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

    def ranked_gap_rows
      rows = used_rank_rows.filter_map do |row|
        card = cards[row[:tool_name]]
        next if card&.strong?

        ranked_row_payload(row, card: card)
      end

      used = rows.map { |row| row[:tool_name] }.to_set
      unused_advertised_tool_rows.each do |row|
        next if row[:card_status] == "registered"
        next unless %w[missing weak].include?(row[:card_status])
        next if used.include?(row[:tool_name])

        rows << row.merge(
          calls: 0,
          errors: 0,
          error_rate: 0.0,
          result_bytes: 0,
          last_used_at: nil,
          server_names: [],
          recommendation: "ignore_for_now"
        )
      end

      rows
        .sort_by { |row| ranked_sort_key(row) }
        .first(Admin::McpToolUsagePayload::DEFAULT_CARD_GAP_LIMIT)
    end

    def used_rank_rows
      @used_rank_rows ||= begin
        grouped = gap_candidate_usages
          .group(:normalized_tool_name)
          .order(Arel.sql("#{count_expression} DESC, #{error_count_expression} DESC, #{result_bytes_expression} DESC, #{last_used_expression} DESC, #{McpToolUsage.quoted_table_name}.normalized_tool_name ASC"))
          .limit(Admin::McpToolUsagePayload::DEFAULT_CARD_GAP_LIMIT)
          .pluck(
            :normalized_tool_name,
            Arel.sql(count_expression),
            Arel.sql(error_count_expression),
            Arel.sql(result_bytes_expression),
            Arel.sql(last_used_expression),
            Arel.sql(server_names_expression)
          )

        grouped.map do |tool_name, count, errors, result_bytes, last_used_at, server_names|
          count = count.to_i
          errors = errors.to_i
          {
            tool_name: tool_name.to_s,
            calls: count,
            errors: errors,
            error_rate: count.positive? ? (errors.to_f / count).round(4) : 0.0,
            result_bytes: result_bytes.to_i,
            last_used_at: last_used_at,
            server_names: server_names.to_s.split(",").reject(&:blank?).sort
          }
        end
      end
    end

    def gap_candidate_usages
      classified_tool_names = (strong_card_tool_names + explicit_decision_tool_names).uniq
      return usages if classified_tool_names.empty?

      usages.where.not(normalized_tool_name: classified_tool_names)
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

    def result_bytes_expression
      "COALESCE(SUM(#{McpToolUsage.quoted_table_name}.result_bytes), 0)"
    end

    def last_used_expression
      "MAX(COALESCE(#{McpToolUsage.quoted_table_name}.completed_at, #{McpToolUsage.quoted_table_name}.started_at, #{McpToolUsage.quoted_table_name}.created_at))"
    end

    def server_names_expression
      "GROUP_CONCAT(DISTINCT #{McpToolUsage.quoted_table_name}.server_name)"
    end

    def missing_card_rows(rows)
      rows.filter_map do |row|
        next unless classification_for(row[:tool_name]) == "missing"

        row_payload(row).merge(card_status: "missing")
      end
    end

    def weak_or_missing_card_rows(rows)
      rows.filter_map do |row|
        card = cards[row[:tool_name]]
        next if card&.strong?
        next if explicit_decisions.key?(row[:tool_name])

        row_payload(row).merge(card_status: card ? "weak" : "missing")
      end
    end

    def unused_advertised_tool_rows
      @unused_advertised_tool_rows ||= begin
        used = usages.distinct.pluck(:normalized_tool_name).map(&:to_s).to_set
        (advertised_tools - used.to_a).map do |tool_name|
          owner = owners[tool_name] || Owner.new(tool_name: tool_name, owner_type: "core", owner_name: "core")
          {
            tool_name: tool_name,
            owner_type: owner.owner_type,
            owner_name: owner.owner_name,
            recommendation_target: owner.recommendation_target,
            card_status: classification_for(tool_name)
          }
        end
      end
    end

    def unclassified_advertised_tool_rows
      advertised_tools.filter_map do |tool_name|
        next unless classification_for(tool_name) == "missing"

        owner = owners[tool_name] || Owner.new(tool_name: tool_name, owner_type: "core", owner_name: "core")
        {
          tool_name: tool_name,
          owner_type: owner.owner_type,
          owner_name: owner.owner_name,
          recommendation_target: owner.recommendation_target,
          guidance: "Add a tool card under app/frontend/routes/chat/tool_cards or plugins/*/app/frontend/tool_cards, or add an explicit generic/deferred/hidden decision in Admin::McpToolCardCoverage::EXPLICIT_CARD_DECISIONS."
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

    def ranked_row_payload(row, card:)
      row_payload(row).merge(
        card_status: card ? "weak" : "missing",
        result_bytes: row[:result_bytes],
        last_used_at: iso8601_time(row[:last_used_at]),
        server_names: row[:server_names],
        recommendation: recommendation_for(row)
      )
    end

    def recommendation_for(row)
      return "custom_card_next" if row[:calls] >= 10 || row[:errors].positive? || row[:result_bytes] >= 64.kilobytes
      return "watch" if row[:calls].positive?

      "ignore_for_now"
    end

    def ranked_sort_key(row)
      [
        -row[:calls].to_i,
        -row[:errors].to_i,
        -row[:result_bytes].to_i,
        row[:last_used_at].present? ? -Time.zone.parse(row[:last_used_at].to_s).to_i : 0,
        row[:tool_name].to_s
      ]
    end

    def iso8601_time(value)
      return if value.blank?
      return value.iso8601 if value.respond_to?(:iso8601)

      Time.zone.parse(value.to_s)&.iso8601
    rescue ArgumentError, TypeError
      nil
    end

    def owners
      @owners ||= core_tool_owners.merge(plugin_tool_owners)
    end

    def strong_card_tool_names
      @strong_card_tool_names ||= cards.values.select(&:strong?).map(&:tool_name)
    end

    def explicit_decision_tool_names
      @explicit_decision_tool_names ||= explicit_decisions.keys
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
        cards_from_path(path).each do |card|
          index[card.tool_name] = card
        end
      end
    end

    def card_paths
      (Dir.glob(Rails.root.join(CORE_CARD_GLOB).to_s) + Dir.glob(Rails.root.join(PLUGIN_CARD_GLOB).to_s))
        .reject { |path| path.match?(TEST_CARD_PATTERN) }
    end

    def cards_from_path(path)
      source = File.read(path)
      tool_names = tool_names_from_source(source)
      return [] if tool_names.empty?

      owner_type, owner_name = card_owner(path)
      tool_names.map do |tool_name|
        Card.new(
          tool_name: tool_name,
          owner_type: owner_type,
          owner_name: owner_name,
          has_collapsed_summary: source.include?("collapsedSummary") || shared_card_registration?(source, tool_name),
          path: relative_path(path)
        )
      end
    rescue Errno::ENOENT
      []
    end

    def tool_names_from_source(source)
      ([ source[TOOL_NAME_PATTERN, 1] ] + SHARED_CARD_PATTERNS.flat_map { |pattern| source.scan(pattern).flatten })
        .compact_blank
        .uniq
    end

    def shared_card_registration?(source, tool_name)
      SHARED_CARD_PATTERNS.any? { |pattern| source.match?(pattern) && source.scan(pattern).flatten.include?(tool_name) }
    end

    def classification_for(tool_name)
      card = cards[tool_name]
      return card.strong? ? "registered" : "weak" if card

      explicit_decisions[tool_name]&.status || "missing"
    end

    def explicit_decisions
      @explicit_decisions ||= EXPLICIT_CARD_DECISIONS.to_h do |tool_name, decision|
        [
          tool_name,
          CardDecision.new(tool_name: tool_name, status: decision.fetch(:status), reason: decision.fetch(:reason))
        ]
      end
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
