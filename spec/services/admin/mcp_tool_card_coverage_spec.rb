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

  it "separates missing high-volume cards, weak high-error cards, and unused advertised tools by owner" do
    add_card("app/frontend/routes/chat/tool_cards/core_used_tool.tsx", <<~TS)
      export default { toolName: "core_used_tool", collapsedSummary: () => "ok", renderExpanded: () => null }
    TS
    add_card("plugins/coverage_plugin/app/frontend/tool_cards/plugin_error_tool.tsx", <<~TS)
      export default { toolName: "plugin_error_tool", renderExpanded: () => null }
    TS

    create_usage("core_used_tool", count: 4)
    create_usage("core_missing_tool", count: 12, result_bytes: 2048, server_name: "syrus-chat-sidecar")
    create_usage("plugin_used_tool", count: 9, result_bytes: 40.kilobytes, server_name: "plugin-sidecar")
    create_usage("plugin_error_tool", count: 5, errors: 3, result_bytes: 1024, server_name: "plugin-sidecar")
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

    priorities = report.fetch(:card_gap_priorities)
    expect(priorities.first).to include(
      tool_name: "plugin_used_tool",
      calls: 9,
      result_bytes: 9 * 40.kilobytes,
      server_names: [ "plugin-sidecar" ],
      priority_label: "build_next",
      card_status: "missing"
    )
    expect(priorities).to include(
      include(tool_name: "core_missing_tool", calls: 12, result_bytes: 12 * 2048, last_used_at: match(/\A\d{4}-\d{2}-\d{2}T/), priority_label: "build_next"),
      include(tool_name: "plugin_error_tool", errors: 3, priority_label: "investigate_errors", card_status: "weak"),
      include(tool_name: "plugin_unused_tool", calls: 0, result_bytes: 0, last_used_at: nil, priority_label: "defer")
    )

    expect(report.fetch(:unused_advertised_tools)).to include(
      include(tool_name: "core_unused_tool", owner_type: "core", recommendation_target: "core", card_status: "missing"),
      include(tool_name: "plugin_unused_tool", owner_type: "plugin", owner_name: "coverage_plugin", recommendation_target: "plugin:coverage_plugin", card_status: "missing")
    )
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
        result_bytes: result_bytes,
        started_at: index.minutes.ago,
        completed_at: index.minutes.ago
      )
    end
  end
end
