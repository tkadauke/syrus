require "rails_helper"
require "tmpdir"

RSpec.describe Admin::McpToolCardCoverage, :reset_plugin_registry do
  around do |example|
    Dir.mktmpdir("tool-card-coverage") do |dir|
      @card_dir = Pathname.new(dir)
      @card_paths = []
      example.run
    end
  end

  let(:plugin_tool_set) do
    Class.new do
      include Syrus::Plugin::ChatMcpToolSet

      def self.available_for?(_chat_session, tier:)
        tier.to_sym == :essential
      end

      def self.tool_definitions(tier:)
        [
          { name: "plugin_used_tool", description: "Used plugin tool", input_schema: {} },
          { name: "plugin_error_tool", description: "Erroring plugin tool", input_schema: {} },
          { name: "plugin_unused_tool", description: "Unused plugin tool", input_schema: {} }
        ]
      end
    end
  end

  before do
    allow_any_instance_of(described_class).to receive(:card_paths) { @card_paths }

    Syrus::PluginRegistry.register(
      name: "coverage_plugin",
      version: "1.0.0",
      provides: { chat_mcp_tool_set: plugin_tool_set }
    )

    allow(McpToolRegistry).to receive(:summaries).and_call_original
    allow(McpToolRegistry).to receive(:summaries).with(surface: :chat).and_return(
      [
        { tool_name: "core_used_tool" },
        { tool_name: "core_missing_tool" },
        { tool_name: "core_error_tool" },
        { tool_name: "core_unused_tool" }
      ]
    )
  end

  it "attributes session-dependent plugin tools using the current chat session" do
    admin = Factories.user(admin: true)
    chat_session = ChatSession.create!(user: admin, title: "Admin chat")
    session_tool_set = Class.new do
      include Syrus::Plugin::ChatMcpToolSet

      def self.available_for?(_chat_session, tier:)
        tier.to_sym == :essential
      end

      def self.tool_definitions(tier:, chat_session: nil)
        return [
          { name: "session_visible_tool", description: "Visible", input_schema: {} },
          { name: "admin_visible_tool", description: "Admin", input_schema: {} }
        ] if tier.nil?
        return [] unless tier.to_sym == :essential

        tools = [ { name: "session_visible_tool", description: "Visible", input_schema: {} } ]
        tools << { name: "admin_visible_tool", description: "Admin", input_schema: {} } if chat_session&.user&.admin?
        tools
      end
    end

    Syrus::PluginRegistry.register(
      name: "session_plugin",
      version: "1.0.0",
      provides: { chat_mcp_tool_set: session_tool_set }
    )

    report = described_class.call(
      usages: McpToolUsage.none,
      advertised_tools: %w[admin_visible_tool session_visible_tool],
      chat_session: chat_session
    )

    expect(report.fetch(:unused_advertised_tools)).to include(
      include(tool_name: "admin_visible_tool", owner_type: "plugin", owner_name: "session_plugin", recommendation_target: "plugin:session_plugin"),
      include(tool_name: "session_visible_tool", owner_type: "plugin", owner_name: "session_plugin", recommendation_target: "plugin:session_plugin")
    )
  end

  it "attributes deferred-only plugin tools without probing unavailable tiers" do
    deferred_tool_set = Class.new do
      include Syrus::Plugin::ChatMcpToolSet

      def self.available_for?(_chat_session, tier:)
        tier.to_sym == :deferred
      end

      def self.tool_definitions(tier:)
        return [ { name: "deferred_plugin_tool", description: "Deferred", input_schema: {} } ] if tier.nil?
        raise "essential tier should not be inspected" if tier.to_sym == :essential

        [ { name: "deferred_plugin_tool", description: "Deferred", input_schema: {} } ]
      end
    end

    Syrus::PluginRegistry.register(
      name: "deferred_plugin",
      version: "1.0.0",
      provides: { chat_mcp_tool_set: deferred_tool_set }
    )

    report = described_class.call(
      usages: McpToolUsage.none,
      advertised_tools: %w[deferred_plugin_tool]
    )

    expect(report.fetch(:unused_advertised_tools)).to include(
      include(tool_name: "deferred_plugin_tool", owner_type: "plugin", owner_name: "deferred_plugin", recommendation_target: "plugin:deferred_plugin")
    )
  end

  it "classifies advertised tools through card registrations or explicit non-card decisions" do
    stub_const("#{described_class}::EXPLICIT_CARD_STATUSES", {
      "core_generic_tool" => "generic",
      "core_hidden_tool" => "hidden",
      "plugin_deferred_tool" => "deferred"
    }.freeze)

    add_card("app/frontend/routes/chat/tool_cards/core_factory_tool.tsx", <<~TS)
      import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"
      export default maintenanceToolCard("core_factory_tool")
    TS

    deferred_tool_set = Class.new do
      include Syrus::Plugin::ChatMcpToolSet

      def self.available_for?(_chat_session, tier:)
        tier.to_sym == :deferred
      end

      def self.tool_definitions(tier:)
        [
          { name: "plugin_deferred_tool", description: "Deferred plugin tool", input_schema: {} },
          { name: "plugin_unclassified_tool", description: "Plugin tool without a decision", input_schema: {} }
        ]
      end
    end

    unavailable_tool_set = Class.new do
      include Syrus::Plugin::ChatMcpToolSet

      def self.available_for?(_chat_session, tier:)
        false
      end

      def self.tool_definitions(tier:)
        [ { name: "plugin_unavailable_tool", description: "Unavailable plugin tool", input_schema: {} } ]
      end
    end

    Syrus::PluginRegistry.register(
      name: "deferred_decision_plugin",
      version: "1.0.0",
      provides: { chat_mcp_tool_set: deferred_tool_set }
    )
    Syrus::PluginRegistry.register(
      name: "unavailable_decision_plugin",
      version: "1.0.0",
      provides: { chat_mcp_tool_set: unavailable_tool_set }
    )

    advertised_tools = %w[
      core_factory_tool
      core_generic_tool
      core_hidden_tool
      core_unclassified_tool
      plugin_deferred_tool
      plugin_unclassified_tool
    ]

    report = described_class.call(
      usages: McpToolUsage.none,
      advertised_tools: advertised_tools
    )

    expect(report.fetch(:unused_advertised_tools)).to include(
      include(tool_name: "core_factory_tool", card_status: "registered"),
      include(tool_name: "core_generic_tool", card_status: "generic"),
      include(tool_name: "core_hidden_tool", card_status: "hidden"),
      include(tool_name: "plugin_deferred_tool", owner_type: "plugin", owner_name: "deferred_decision_plugin", card_status: "deferred")
    )
    expect(report.fetch(:unused_advertised_tools)).not_to include(include(tool_name: "plugin_unavailable_tool"))
    expect(report.fetch(:unclassified_advertised_tools)).to contain_exactly(
      include(tool_name: "core_unclassified_tool", owner_type: "core", card_status: "missing"),
      include(tool_name: "plugin_unclassified_tool", owner_type: "plugin", owner_name: "deferred_decision_plugin", card_status: "missing")
    )
  end

  it "ranks missing and weak card gaps by usage impact, ownership, and recency" do
    add_card("app/frontend/routes/chat/tool_cards/core_used_tool.tsx", <<~TS)
      export default { toolName: "core_used_tool", collapsedSummary: () => "ok", renderExpanded: () => null }
    TS
    add_card("plugins/coverage_plugin/app/frontend/tool_cards/plugin_error_tool.tsx", <<~TS)
      export default { toolName: "plugin_error_tool", renderExpanded: () => null }
    TS

    create_usage("core_used_tool", count: 4)
    travel_to(Time.zone.parse("2026-09-08 12:00:00")) { create_usage("core_missing_tool", count: 12, result_bytes: 1024, server_name: "syrus-chat-sidecar") }
    travel_to(Time.zone.parse("2026-09-08 12:05:00")) { create_usage("plugin_used_tool", count: 9, result_bytes: 96.kilobytes, server_name: "plugin-sidecar") }
    travel_to(Time.zone.parse("2026-09-08 12:10:00")) { create_usage("plugin_error_tool", count: 5, errors: 3, result_bytes: 512, server_name: "plugin-sidecar") }
    create_usage("core_error_tool", count: 4, errors: 2)
    create_usage("workflow_only_tool", count: 20, surface: "workflow")

    report = described_class.call(
      usages: McpToolUsage.where(surface: "chat"),
      advertised_tools: %w[
        core_used_tool
        core_missing_tool
        core_error_tool
        core_unused_tool
        plugin_used_tool
        plugin_error_tool
        plugin_unused_tool
      ]
    )

    expect(report.fetch(:ranked_gaps)).to include(
      include(
        tool_name: "core_missing_tool",
        calls: 12,
        result_bytes: 12_288,
        last_used_at: "2026-09-08T12:00:00Z",
        server_names: [ "syrus-chat-sidecar" ],
        owner_type: "core",
        card_status: "missing",
        recommendation: "custom_card_next"
      ),
      include(
        tool_name: "plugin_used_tool",
        calls: 9,
        result_bytes: 884_736,
        owner_type: "plugin",
        owner_name: "coverage_plugin",
        server_names: [ "plugin-sidecar" ],
        recommendation_target: "plugin:coverage_plugin",
        recommendation: "custom_card_next"
      ),
      include(
        tool_name: "plugin_error_tool",
        errors: 3,
        card_status: "weak",
        recommendation: "custom_card_next"
      ),
      include(
        tool_name: "plugin_unused_tool",
        calls: 0,
        result_bytes: 0,
        last_used_at: nil,
        owner_type: "plugin",
        recommendation: "ignore_for_now"
      )
    )
    expect(report.fetch(:ranked_gaps).first).to include(tool_name: "core_missing_tool")
    expect(report.fetch(:ranked_gaps)).not_to include(include(tool_name: "core_used_tool"))

    expect(report.fetch(:high_volume_without_custom_card)).to include(
      include(tool_name: "core_missing_tool", calls: 12, owner_type: "core", recommendation_target: "core", card_status: "missing"),
      include(tool_name: "plugin_used_tool", calls: 9, owner_type: "plugin", owner_name: "coverage_plugin", recommendation_target: "plugin:coverage_plugin", card_status: "missing")
    )
    expect(report.fetch(:high_volume_without_custom_card)).not_to include(include(tool_name: "core_used_tool"))
    expect(report.fetch(:high_volume_without_custom_card)).not_to include(include(tool_name: "workflow_only_tool"))

    expect(report.fetch(:high_error_with_weak_or_no_custom_card)).to include(
      include(tool_name: "plugin_error_tool", errors: 3, error_rate: 0.6, owner_type: "plugin", recommendation_target: "plugin:coverage_plugin", card_status: "weak"),
      include(tool_name: "core_error_tool", errors: 2, error_rate: 0.5, owner_type: "core", recommendation_target: "core", card_status: "missing")
    )

    expect(report.fetch(:unused_advertised_tools)).to include(
      include(tool_name: "core_unused_tool", owner_type: "core", recommendation_target: "core", card_status: "missing"),
      include(tool_name: "plugin_unused_tool", owner_type: "plugin", owner_name: "coverage_plugin", recommendation_target: "plugin:coverage_plugin", card_status: "missing")
    )
  end

  it "does not let strong custom cards crowd real gaps out of the ranked dashboard" do
    105.times do |index|
      tool_name = "covered_tool_#{index}"
      add_card("app/frontend/routes/chat/tool_cards/#{tool_name}.tsx", <<~TS)
        export default { toolName: "#{tool_name}", collapsedSummary: () => "ok", renderExpanded: () => null }
      TS
      create_usage(tool_name, count: 2)
    end
    create_usage("low_volume_missing_tool", count: 1, result_bytes: 256, server_name: "syrus-chat-sidecar")

    report = described_class.call(
      usages: McpToolUsage.where(surface: "chat"),
      advertised_tools: [ "low_volume_missing_tool" ] + 105.times.map { |index| "covered_tool_#{index}" }
    )

    expect(report.fetch(:ranked_gaps)).to include(
      include(
        tool_name: "low_volume_missing_tool",
        calls: 1,
        result_bytes: 256,
        server_names: [ "syrus-chat-sidecar" ],
        card_status: "missing",
        recommendation: "watch"
      )
    )
    expect(report.fetch(:ranked_gaps)).not_to include(include(tool_name: "covered_tool_0"))
  end

  def add_card(relative_path, source)
    path = @card_dir.join(relative_path)
    FileUtils.mkdir_p(path.dirname)
    File.write(path, source)
    @card_paths << path.to_s
  end

  def create_usage(tool_name, count:, errors: 0, surface: "chat", result_bytes: nil, server_name: nil)
    count.times do |index|
      failed = index < errors
      McpToolUsage.create!(
        surface: surface,
        raw_tool_name: tool_name,
        server_name: server_name,
        tool_name: tool_name,
        normalized_tool_name: tool_name,
        status: failed ? "failed" : "completed",
        error: failed,
        started_at: Time.current,
        completed_at: Time.current,
        result_bytes: result_bytes
      )
    end
  end
end

RSpec.describe "chat MCP custom-card coverage inventory" do
  it "classifies every currently advertised chat tool with a card or explicit decision" do
    report = Admin::McpToolCardCoverage.call(
      usages: McpToolUsage.none,
      advertised_tools: McpToolUsageRecorder.advertised_tools(surface: "chat")
    )

    expect(report.fetch(:unclassified_advertised_tools)).to eq([])
  end
end
