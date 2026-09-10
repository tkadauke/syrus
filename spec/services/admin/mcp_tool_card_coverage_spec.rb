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

  it "separates missing high-volume cards, weak high-error cards, and unused advertised tools by owner" do
    add_card("app/frontend/routes/chat/tool_cards/core_used_tool.tsx", <<~TS)
      export default { toolName: "core_used_tool", collapsedSummary: () => "ok", renderExpanded: () => null }
    TS
    add_card("plugins/coverage_plugin/app/frontend/tool_cards/plugin_error_tool.tsx", <<~TS)
      export default { toolName: "plugin_error_tool", renderExpanded: () => null }
    TS

    create_usage("core_used_tool", count: 4)
    create_usage("core_missing_tool", count: 12)
    create_usage("plugin_used_tool", count: 9)
    create_usage("plugin_error_tool", count: 5, errors: 3)
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
      include(
        tool_name: "core_missing_tool",
        calls: 12,
        owner_type: "core",
        owner_name: "core",
        recommendation_target: "core",
        card_status: "missing"
      ),
      include(
        tool_name: "plugin_used_tool",
        calls: 9,
        owner_type: "plugin",
        owner_name: "coverage_plugin",
        recommendation_target: "plugin:coverage_plugin",
        card_status: "missing"
      )
    )
    expect(report.fetch(:high_volume_without_custom_card)).not_to include(include(tool_name: "core_used_tool"))
    expect(report.fetch(:high_volume_without_custom_card)).not_to include(include(tool_name: "workflow_only_tool"))

    expect(report.fetch(:high_error_with_weak_or_no_custom_card)).to include(
      include(
        tool_name: "plugin_error_tool",
        errors: 3,
        error_rate: 0.6,
        owner_type: "plugin",
        owner_name: "coverage_plugin",
        recommendation_target: "plugin:coverage_plugin",
        card_status: "weak"
      ),
      include(
        tool_name: "core_error_tool",
        errors: 2,
        error_rate: 0.5,
        owner_type: "core",
        owner_name: "core",
        recommendation_target: "core",
        card_status: "missing"
      )
    )

    expect(report.fetch(:unused_advertised_tools)).to include(
      include(
        tool_name: "core_unused_tool",
        owner_type: "core",
        recommendation_target: "core",
        card_status: "missing"
      ),
      include(
        tool_name: "plugin_unused_tool",
        owner_type: "plugin",
        owner_name: "coverage_plugin",
        recommendation_target: "plugin:coverage_plugin",
        card_status: "missing"
      )
    )
  end

  def add_card(relative_path, source)
    path = @card_dir.join(relative_path)
    FileUtils.mkdir_p(path.dirname)
    File.write(path, source)
    @card_paths << path.to_s
  end

  def create_usage(tool_name, count:, errors: 0, surface: "chat")
    count.times do |index|
      failed = index < errors
      McpToolUsage.create!(
        surface: surface,
        raw_tool_name: tool_name,
        tool_name: tool_name,
        normalized_tool_name: tool_name,
        status: failed ? "failed" : "completed",
        error: failed,
        started_at: Time.current,
        completed_at: Time.current
      )
    end
  end
end
