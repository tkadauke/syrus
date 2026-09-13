module Admin
  class McpToolCardCoverage
    Card = Data.define(:tool_name, :owner_type, :owner_name, :has_collapsed_summary, :path) do
      def strong? = has_collapsed_summary
    end

    Owner = Data.define(:tool_name, :owner_type, :owner_name, :tier, :mutation) do
      def recommendation_target
        owner_type == "plugin" ? "plugin:#{owner_name}" : "core"
      end
    end

    Tool = Data.define(:tool_name, :owner, :card) do
      def core_owned? = owner.owner_type == "core"
      def plugin_owned? = owner.owner_type == "plugin"
      def deferred? = owner.tier == "deferred"
      def mutating? = owner.mutation == true
      def card_owner_type = card&.owner_type
      def custom_card? = card.present?
      def strong_card? = card&.strong? == true
    end

    CORE_CARD_GLOB = "app/frontend/routes/chat/tool_cards/*.tsx"
    PLUGIN_CARD_GLOB = "plugins/*/app/frontend/tool_cards/*.tsx"
    TEST_CARD_PATTERN = /\.test\.tsx\z/
    TOOL_NAME_PATTERNS = [
      /toolName:\s*["']([^"']+)["']/,
      /export\s+default\s+\w+\(["']([^"']+)["']\)/
    ].freeze
    GENERIC_CARD_ACCEPTABLE_TOOLS = Set.new([
      "read_file",
      "write_file",
      "run_command",
      "git_diff",
      "git_status",
      "read_run_transcript",
      "read_chat_messages",
      "read_worker_health",
      "admin_read_operational_logs"
    ]).freeze
    HIDDEN_ACK_ONLY_TOOLS = Set.new([
      "set_bookmark",
      "rename_chat",
      "mark_goal_completed",
      "mark_goal_blocked",
      "submit_chat_feedback"
    ]).freeze

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
        unused_advertised_tools: unused_advertised_tool_rows,
        classification_counts: classification_counts,
        classified_tools: classified_tool_rows,
        unclassified_tools: unclassified_tool_rows
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
        coverage = classification_for(row[:tool_name])
        next if coverage[:has_custom_card]
        next unless coverage[:classification] == "unclassified"

        row_payload(row).merge(card_status: "missing", classification: coverage[:classification])
      end
    end

    def weak_or_missing_card_rows(rows)
      rows.filter_map do |row|
        coverage = classification_for(row[:tool_name])
        next if coverage[:card_status] == "registered"
        next unless coverage[:classification] == "custom_card" || coverage[:classification] == "plugin_custom_card" || coverage[:classification] == "unclassified"

        row_payload(row).merge(card_status: coverage[:card_status], classification: coverage[:classification])
      end
    end

    def unused_advertised_tool_rows
      used = usages.distinct.pluck(:normalized_tool_name).map(&:to_s).to_set
      (advertised_tools - used.to_a).map do |tool_name|
        classification_for(tool_name).slice(
          :tool_name,
          :owner_type,
          :owner_name,
          :recommendation_target,
          :card_status,
          :classification
        )
      end
    end

    def row_payload(row)
      coverage = classification_for(row[:tool_name])
      {
        tool_name: row[:tool_name],
        calls: row[:calls],
        errors: row[:errors],
        error_rate: row[:error_rate],
        owner_type: coverage[:owner_type],
        owner_name: coverage[:owner_name],
        recommendation_target: coverage[:recommendation_target]
      }
    end

    def classified_tool_rows
      classified_tool_names.map { |tool_name| classification_for(tool_name) }
    end

    def classified_tool_names
      return advertised_tools unless single_tool_name

      advertised_tools.include?(single_tool_name) ? [ single_tool_name ] : []
    end

    def unclassified_tool_rows
      classified_tool_rows.select { |row| row[:classification] == "unclassified" }
    end

    def classification_counts
      classified_tool_rows
        .group_by { |row| row[:classification] }
        .transform_values(&:count)
        .sort
        .to_h
    end

    def classification_for(tool_name)
      tool = Tool.new(
        tool_name: tool_name,
        owner: owners[tool_name] || Owner.new(tool_name: tool_name, owner_type: "core", owner_name: "core", tier: nil, mutation: nil),
        card: cards[tool_name]
      )
      classification = CardClassification.for(tool)
      owner = tool.owner
      card = tool.card

      {
        tool_name: tool.tool_name,
        owner_type: owner.owner_type,
        owner_name: owner.owner_name,
        recommendation_target: owner.recommendation_target,
        tier: owner.tier,
        mutation: owner.mutation,
        card_status: card ? (card.strong? ? "registered" : "weak") : "missing",
        card_owner_type: card&.owner_type,
        card_owner_name: card&.owner_name,
        card_path: card&.path,
        has_custom_card: tool.custom_card?,
        classification: classification.name,
        classification_reason: classification.reason
      }
    end

    def owners
      @owners ||= core_tool_owners.merge(plugin_tool_owners)
    end

    def core_tool_owners
      McpToolRegistry.summaries(surface: :chat).each_with_object({}) do |entry, index|
        tool_name = entry[:tool_name].to_s
        index[tool_name] = Owner.new(
          tool_name: tool_name,
          owner_type: "core",
          owner_name: "core",
          tier: entry[:tier]&.to_s,
          mutation: entry[:mutation] == true
        )
      end
    end

    def plugin_tool_owners
      Syrus::PluginRegistry.all_plugins.each_with_object({}) do |manifest, index|
        plugin_tool_entries(manifest).each do |entry|
          tool_name = entry.fetch(:name)
          next if index.key?(tool_name)

          index[tool_name] = Owner.new(
            tool_name: tool_name,
            owner_type: "plugin",
            owner_name: manifest.name,
            tier: entry[:tier],
            mutation: entry[:mutation]
          )
        end
      end
    end

    def plugin_tool_entries(manifest)
      Array(manifest.provides[:chat_mcp_tool_set]).flat_map do |tool_set|
        %i[essential deferred].flat_map do |tier|
          tool_definitions(tool_set, tier: tier).filter_map do |definition|
            name = definition[:name].presence&.to_s
            next if name.blank?

            { name: name, tier: tier.to_s, mutation: definition[:mutation] == true }
          end
        end
      end
        .uniq
    end

    def tool_definitions(tool_set, tier: nil)
      method = tool_set.method(:tool_definitions)
      keywords = method.parameters.select { |type, _name| type == :key || type == :keyreq }.map(&:last)
      return Array(tool_set.tool_definitions(tier: tier)) if keywords.include?(:tier)
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
      tool_name = TOOL_NAME_PATTERNS.lazy.filter_map { |pattern| source[pattern, 1] }.first
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
      match = relative.match(%r{(?:\A|/)plugins/([^/]+)/})
      return [ "plugin", match[1] ] if match

      [ "core", "core" ]
    end

    def relative_path(path)
      Pathname.new(path).relative_path_from(Rails.root).to_s
    rescue ArgumentError
      path.to_s
    end

    class CardClassification
      Result = Data.define(:name, :reason)

      class << self
        def for(tool)
          classifiers.each do |classifier|
            result = classifier.call(tool)
            return result if result
          end
        end

        private

        def classifiers
          @classifiers ||= [
            PluginCustomCard,
            CoreCustomCard,
            GenericCardAcceptable,
            HiddenAckOnly,
            IntentionallyObscureDeferred,
            Unclassified
          ].freeze
        end
      end

      class PluginCustomCard
        def self.call(tool)
          return unless tool.card_owner_type == "plugin"

          Result.new(name: "plugin_custom_card", reason: "plugin-owned custom card renderer is registered")
        end
      end

      class CoreCustomCard
        def self.call(tool)
          return unless tool.custom_card?

          Result.new(name: "custom_card", reason: "core custom card renderer is registered")
        end
      end

      class GenericCardAcceptable
        def self.call(tool)
          return unless GENERIC_CARD_ACCEPTABLE_TOOLS.include?(tool.tool_name)

          Result.new(name: "generic_card_acceptable", reason: "raw transcript-style output is acceptable for this diagnostic tool")
        end
      end

      class HiddenAckOnly
        def self.call(tool)
          return unless HIDDEN_ACK_ONLY_TOOLS.include?(tool.tool_name)

          Result.new(name: "hidden_ack_only", reason: "successful calls are acknowledgement-only or normally hidden from chat")
        end
      end

      class IntentionallyObscureDeferred
        def self.call(tool)
          return unless tool.deferred?

          Result.new(name: "intentionally_obscure_deferred", reason: "deferred-tier tool is intentionally obscure unless usage proves card value")
        end
      end

      class Unclassified
        def self.call(_tool)
          Result.new(name: "unclassified", reason: "advertised chat tool has no registered card or explicit coverage classification")
        end
      end
    end
  end
end
